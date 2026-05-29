"""
Groups API Router - CRUD operations for group chats.

Endpoints:
- POST /api/groups - Create a group
- GET /api/groups/mine - Get user's groups
- GET /api/groups/{id} - Get group details
- PATCH /api/groups/{id} - Update group info (admin)
- POST /api/groups/{id}/members - Add members
- POST /api/groups/{id}/members/{user_id}/kick - Kick member (admin)
- POST /api/groups/{id}/members/{user_id}/promote - Promote to admin
- POST /api/groups/{id}/members/{user_id}/demote - Demote from admin
- POST /api/groups/{id}/leave - Leave group
- POST /api/groups/{id}/invite-link - Create/get invite link (admin)
- DELETE /api/groups/{id}/invite-link - Reset invite link (admin)
- POST /api/groups/join/{invite_code} - Join via invite link
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime

from database import get_db
from models import User, Group, GroupMember, GroupMessage, GroupInviteLink, Notification, Mention, GroupPoll, GroupPollOption, GroupPollVote, GroupMask, VoiceChain, VoiceChainLink
from routers.users import get_current_user
from encryption import encrypt_text, decrypt_text
import json
import uuid
import secrets
import ws_manager

router = APIRouter(prefix="/api/groups", tags=["groups"])


# ═══════════════════════════════════════════════════════════════════════════
# REQUEST/RESPONSE MODELS
# ═══════════════════════════════════════════════════════════════════════════

class CreateGroupRequest(BaseModel):
    name: str
    member_ids: List[str]  # User IDs to add as members
    avatar_url: Optional[str] = None
    description: Optional[str] = None
    # Round 47 — optional client-side UUID. When provided AND the
    # server doesn't already have a group with this id, the server
    # adopts it as the canonical group id (offline-first path —
    # iOS may have created the group locally while offline and
    # already keyed messages/conversations off this UUID; remapping
    # at reconcile time is expensive + lossy).
    client_id: Optional[str] = None


class GroupMemberResponse(BaseModel):
    user_id: str
    username: str
    avatar_url: Optional[str]
    role: str
    joined_at: datetime
    
    class Config:
        from_attributes = True


class GroupResponse(BaseModel):
    id: str
    name: str
    avatar_url: Optional[str]
    description: Optional[str]
    created_by: str
    creator_username: Optional[str]
    created_at: datetime
    member_count: int
    members: Optional[List[GroupMemberResponse]] = None
    is_frozen: bool = False
    frozen_by: Optional[str] = None
    
    class Config:
        from_attributes = True


class AddMembersRequest(BaseModel):
    member_ids: List[str]

class UpdateGroupRequest(BaseModel):
    name: Optional[str] = None
    avatar_url: Optional[str] = None
    description: Optional[str] = None
    visibility: Optional[str] = None  # "public" or "private"
    link_join_enabled: Optional[bool] = None

class InviteLinkResponse(BaseModel):
    invite_code: str
    group_id: str
    created_by: str
    enabled: bool
    use_count: int
    max_uses: Optional[int] = None
    expires_at: Optional[datetime] = None


# ═══════════════════════════════════════════════════════════════════════════
# ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════

@router.post("", response_model=GroupResponse)
async def create_group(
    req: CreateGroupRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Create a new group chat.

    - Creator is automatically added as admin
    - Member IDs must be valid user IDs

    🟦 ROUND 47 (2026-05-17) — full lifecycle propagation.
    Previously this handler:
      1. Wrote `groups` + `group_members` rows
      2. Wrote one `Notification(type="added_to_group")` row per member
    But it never PUSHED anything. So:
      • An online member ("B") learned about the new group only on
        their next `/api/groups/mine` poll (could be 30s+ later).
      • A mesh-only member ("C") connected to B via BLE never learned
        about the group at all — the bridge-downlink handler returned
        only chat messages, not lifecycle events. The user reported
        this as "group never appears on C".

    Fix:
      1. Send WebSocket push `{type: "added_to_group", group: {...full
         metadata + members...}}` to every member (other than creator)
         so online clients react in real time.
      2. The B-side iOS WS handler then materializes the group AND
         mesh-broadcasts a `group_create` envelope to its BLE peers
         (which gets the metadata to C via the spray network).
      3. Independently, the bridge-downlink handler also surfaces
         recently-created groups for the polling bridge's BLE peers —
         see `/api/messages/bridge-downlink` for the safety-net path.
    """
    if not req.name or not req.name.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Group name is required"
        )

    # Round 47: honour the optional client_id so an offline-first
    # group keeps its locally-generated UUID after server reconcile —
    # avoids the message-row remap that the previous server-assigns-new-id
    # path required. iOS sends `clientId` (camelCase via Pydantic alias
    # below or the snake-case alternative).
    client_id = getattr(req, "client_id", None) or getattr(req, "clientId", None)

    # Idempotency: if a group with this client_id already exists AND
    # the caller is its creator OR a current member, return the
    # existing group.
    #
    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — broaden from
    # "creator-only" to "creator-or-member".
    #
    # SCENARIO: A creates a group offline (local_xxxx). B (online
    # bridger) proxy-creates the server row on A's behalf when
    # bridging A's first mesh message — see BLEMeshEngine.bridge
    # MeshMessageToServer ROUND 71 p3 block. The server now has
    # B as `created_by`. When A eventually comes online and calls
    # syncPendingGroups with `client_id=local_xxxx`, pre-fix the
    # creator-mismatch branch returned 409 → A's pending group
    # stayed pending forever → A never reconciled.
    #
    # Now: if A is a current member of the existing row (which is
    # always the case since B proxy-creates with A in the members
    # list), treat as idempotent and return the existing group. A
    # accepts B as the server-side creator (admin role swap is the
    # trade-off documented in BLEMeshEngine). The 409 stays for
    # the genuine collision case (different user, NOT a member —
    # unlikely random UUID collision).
    if client_id:
        existing = db.query(Group).filter(Group.id == client_id).first()
        if existing is not None:
            is_creator = (existing.created_by == current_user.id)
            is_member = db.query(GroupMember).filter(
                GroupMember.group_id == existing.id,
                GroupMember.user_id == current_user.id,
            ).first() is not None
            if not is_creator and not is_member:
                # Different creator AND not a member — refuse rather
                # than overwrite. The safe behaviour is to error out.
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="A group with that client_id already exists under a different creator",
                )
            existing_member_count = db.query(GroupMember).filter(
                GroupMember.group_id == existing.id
            ).count()
            print(f"👥 [Groups] IDEMPOTENT — client_id={client_id[:8]} already exists "
                  f"(is_creator={is_creator}, is_member={is_member}), returning existing group")
            # Look up creator's username for the response so the
            # caller (e.g. original creator A reconciling after a
            # proxy-create by B) gets the real server-side creator
            # name, not their own.
            creator_user = db.query(User).filter(User.id == existing.created_by).first()
            creator_username = creator_user.username if creator_user else current_user.username
            return GroupResponse(
                id=existing.id,
                name=existing.name,
                avatar_url=existing.avatar_url,
                description=existing.description,
                created_by=existing.created_by,
                creator_username=creator_username,
                created_at=existing.created_at,
                member_count=existing_member_count,
                is_frozen=existing.is_frozen or False,
                frozen_by=existing.frozen_by,
            )

    # Create the group
    group_kwargs = dict(
        name=req.name.strip(),
        avatar_url=req.avatar_url,
        description=req.description,
        created_by=current_user.id,
    )
    if client_id:
        group_kwargs["id"] = client_id
    group = Group(**group_kwargs)
    db.add(group)
    db.flush()  # Get the group ID

    # Add creator as admin
    creator_member = GroupMember(
        group_id=group.id,
        user_id=current_user.id,
        role="admin"
    )
    db.add(creator_member)

    # Add other members
    added_member_ids = [current_user.id]
    member_count = 1  # Creator
    for member_id in req.member_ids:
        if member_id == current_user.id:
            continue  # Skip creator (already added)

        # Verify user exists
        user = db.query(User).filter(User.id == member_id).first()
        if user:
            member = GroupMember(
                group_id=group.id,
                user_id=member_id,
                role="member"
            )
            db.add(member)
            added_member_ids.append(member_id)
            member_count += 1

    db.commit()
    db.refresh(group)

    # Build the full member list (with usernames + avatars) so the
    # WS push carries enough info for online clients to materialize
    # the group locally + mesh-broadcast immediately. Avoids a
    # subsequent /api/groups/{id} fetch.
    members_rows = db.query(GroupMember, User).join(
        User, User.id == GroupMember.user_id
    ).filter(GroupMember.group_id == group.id).all()

    members_payload = [
        {
            "user_id": gm.user_id,
            "username": u.username or "",
            "avatar_url": u.avatar_path,
            "role": gm.role or "member",
            "joined_at": (gm.joined_at or group.created_at).isoformat() + "Z",
        }
        for gm, u in members_rows
    ]

    group_payload = {
        "id": group.id,
        "name": group.name,
        "avatar_url": group.avatar_url,
        "description": group.description,
        "created_by": group.created_by,
        "creator_username": current_user.username,
        "created_at": (group.created_at or datetime.utcnow()).isoformat() + "Z",
        "member_count": member_count,
        "members": members_payload,
    }

    # ✅ Create notification for each added member (so they know they were added)
    for member_id in req.member_ids:
        if member_id == current_user.id:
            continue  # Don't notify creator

        notif = Notification(
            user_id=member_id,
            type="added_to_group",
            data=json.dumps({
                "group_id": group.id,
                "group_name": group.name,
                "added_by": current_user.username,
                "added_by_id": current_user.id,
                # Round 47: full group payload so iOS handler can
                # materialize the group WITHOUT a follow-up
                # /api/groups/{id} fetch (avoids race on slow links).
                "group": group_payload,
            }),
            is_read=False
        )
        db.add(notif)

    db.commit()
    print(f"👥 [Groups] Created group '{group.name}' with {member_count} members by {current_user.username}")
    print(f"🔔 [Groups] Sent notifications to {member_count - 1} members")

    # 🟦 ROUND 47 — push the full group lifecycle event to every
    # online member. The payload mirrors the `GroupSyncPayload`
    # the iOS mesh receiver expects, so the WS handler can either:
    #   • materialize the group locally directly from this payload,
    #     skipping the /api/groups/{id} round-trip; AND/OR
    #   • re-broadcast it over mesh as a `group_create` envelope
    #     for its BLE-only neighbours.
    ws_payload = {
        "type": "added_to_group",
        "group_id": group.id,
        "group_name": group.name,
        "added_by": current_user.username,
        "added_by_id": current_user.id,
        "group": group_payload,
    }
    for member_id in [m for m in added_member_ids if m != current_user.id]:
        try:
            await ws_manager.notify(member_id, ws_payload)
        except Exception as e:
            print(f"⚠️ [Groups] WS push failed for member {member_id[:8]}: {e}")

    return GroupResponse(
        id=group.id,
        name=group.name,
        avatar_url=group.avatar_url,
        description=group.description,
        created_by=group.created_by,
        creator_username=current_user.username,
        created_at=group.created_at,
        member_count=member_count,
        is_frozen=group.is_frozen or False,
        frozen_by=group.frozen_by
    )


@router.get("/mine", response_model=List[GroupResponse])
def get_my_groups(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get all groups the current user is a member of.
    """
    # Find all group memberships for current user
    memberships = db.query(GroupMember).filter(
        GroupMember.user_id == current_user.id
    ).all()
    
    group_ids = [m.group_id for m in memberships]
    
    if not group_ids:
        return []
    
    # Fetch groups
    groups = db.query(Group).filter(Group.id.in_(group_ids)).all()
    
    result = []
    
    # ⚡ Batch: get all member counts in one query
    from sqlalchemy import func
    member_counts = dict(
        db.query(GroupMember.group_id, func.count(GroupMember.id))
        .filter(GroupMember.group_id.in_(group_ids))
        .group_by(GroupMember.group_id)
        .all()
    )
    
    # ⚡ Batch: get all creators in one query
    creator_ids = set(g.created_by for g in groups)
    creators = {u.id: u for u in db.query(User).filter(User.id.in_(creator_ids)).all()} if creator_ids else {}
    
    for group in groups:
        creator = creators.get(group.created_by)
        result.append(GroupResponse(
            id=group.id,
            name=group.name,
            avatar_url=group.avatar_url,
            description=group.description,
            created_by=group.created_by,
            creator_username=creator.username if creator else None,
            created_at=group.created_at,
            member_count=member_counts.get(group.id, 0),
            is_frozen=group.is_frozen or False,
            frozen_by=group.frozen_by
        ))
    
    print(f"👥 [Groups] User {current_user.username} has {len(result)} groups")
    return result


@router.get("/{group_id}", response_model=GroupResponse)
def get_group_details(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get group details including member list.
    Only accessible to group members.
    """
    # Verify user is a member
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    
    if not membership:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You are not a member of this group"
        )
    
    # Fetch group
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Group not found"
        )
    
    # Get all members with user info
    members = db.query(GroupMember).filter(GroupMember.group_id == group_id).all()
    user_ids = [m.user_id for m in members]
    users = {u.id: u for u in db.query(User).filter(User.id.in_(user_ids)).all()}
    
    member_responses = []
    for m in members:
        user = users.get(m.user_id)
        if user:
            member_responses.append(GroupMemberResponse(
                user_id=m.user_id,
                username=user.username or "Unknown",
                avatar_url=user.avatar_path,
                role=m.role,
                joined_at=m.joined_at
            ))
    
    # Get creator username
    creator = db.query(User).filter(User.id == group.created_by).first()
    
    return GroupResponse(
        id=group.id,
        name=group.name,
        avatar_url=group.avatar_url,
        description=group.description,
        created_by=group.created_by,
        creator_username=creator.username if creator else None,
        created_at=group.created_at,
        member_count=len(members),
        members=member_responses,
        is_frozen=group.is_frozen or False,
        frozen_by=group.frozen_by
    )


@router.post("/{group_id}/members", response_model=GroupResponse)
def add_members(
    group_id: str,
    req: AddMembersRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Add members to a group.
    Only admin can add members.
    """
    # Verify user is admin
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    
    if not membership or membership.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only admins can add members"
        )
    
    # Add members
    added_count = 0
    for member_id in req.member_ids:
        # Check if already a member
        existing = db.query(GroupMember).filter(
            GroupMember.group_id == group_id,
            GroupMember.user_id == member_id
        ).first()
        
        if existing:
            continue
        
        # Verify user exists
        user = db.query(User).filter(User.id == member_id).first()
        if user:
            member = GroupMember(
                group_id=group_id,
                user_id=member_id,
                role="member"
            )
            db.add(member)
            added_count += 1
            
            # ✅ Create notification for added member
            # Get group name for notification
            group = db.query(Group).filter(Group.id == group_id).first()
            notif = Notification(
                user_id=member_id,
                type="added_to_group",
                data=json.dumps({
                    "group_id": group_id,
                    "group_name": group.name if group else "Unknown",
                    "added_by": current_user.username,
                    "added_by_id": current_user.id,
                }),
                is_read=False
            )
            db.add(notif)
    
    db.commit()
    
    print(f"👥 [Groups] Added {added_count} members to group {group_id}")
    print(f"🔔 [Groups] Sent notifications to {added_count} new members")
    
    # Fetch updated group
    return get_group_details(group_id, current_user, db)


@router.post("/{group_id}/leave")
def leave_group(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Leave a group.
    If the last admin leaves, the next oldest member becomes admin.
    """
    # Find membership
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    
    if not membership:
        # Idempotent: user is already not a member — treat as success
        return {"success": True, "message": "Already left this group"}
    
    try:
        # Count remaining members
        member_count = db.query(GroupMember).filter(
            GroupMember.group_id == group_id
        ).count()
        
        if member_count == 1:
            # Last member leaving - delete the group and ALL referencing records
            group = db.query(Group).filter(Group.id == group_id).first()
            if group:
                # Clean up FK references that don't have cascade delete
                db.query(GroupMessage).filter(GroupMessage.group_id == group_id).delete()
                db.query(GroupInviteLink).filter(GroupInviteLink.group_id == group_id).delete()
                db.query(GroupPoll).filter(GroupPoll.group_id == group_id).delete()
                db.query(GroupMask).filter(GroupMask.group_id == group_id).delete()
                db.query(VoiceChain).filter(VoiceChain.group_id == group_id).delete()
                db.delete(group)  # Cascades GroupMember via relationship
                db.commit()
                print(f"👥 [Groups] Group {group_id} deleted (last member left)")
                return {"success": True, "message": "Group deleted (you were the last member)"}
        
        # If user is admin, promote next oldest member
        if membership.role == "admin":
            admin_count = db.query(GroupMember).filter(
                GroupMember.group_id == group_id,
                GroupMember.role == "admin"
            ).count()
            
            if admin_count == 1:
                # Promote oldest non-admin member
                next_admin = db.query(GroupMember).filter(
                    GroupMember.group_id == group_id,
                    GroupMember.user_id != current_user.id
                ).order_by(GroupMember.joined_at.asc()).first()
                
                if next_admin:
                    next_admin.role = "admin"
                    print(f"👥 [Groups] Promoted user {next_admin.user_id} to admin")
        
        # Remove membership
        db.delete(membership)

        # 🔴 hacker-audit 2026-05-19 — rotate key on voluntary leave too.
        # A user who leaves had the key, so they could have shared it
        # already. Rotating doesn't unring that bell, but it caps the
        # damage at "messages sent before leave" instead of "every
        # message forever." Same defensive posture as kick.
        try:
            from routers.group_keys import _mint_new_key
            _mint_new_key(db, group_id)
        except Exception as _key_err:
            print(f"⚠️ [Groups] leave: group-key rotation failed for {group_id}: {_key_err}")

        db.commit()

        print(f"👥 [Groups] User {current_user.username} left group {group_id} (key rotated)")

        return {"success": True, "message": "Left group successfully"}
    
    except Exception as e:
        db.rollback()
        print(f"❌ [Groups] leave_group failed for {current_user.username} in {group_id}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to leave group: {str(e)}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# GROUP MESSAGING
# ═══════════════════════════════════════════════════════════════════════════

class MentionEntityPayload(BaseModel):
    type: str = "mention"  # always "mention"
    userId: str
    username: str
    rangeStart: int
    rangeLength: int


class SendGroupMessageRequest(BaseModel):
    content: str
    message_id: Optional[str] = None  # Client-provided UUID for idempotency
    message_type: str = "text"
    audio_url: Optional[str] = None
    audio_duration_seconds: Optional[int] = None
    file_name: Optional[str] = None
    file_size: Optional[int] = None
    mime_type: Optional[str] = None
    reply_to_message_id: Optional[str] = None
    reply_to_text_preview: Optional[str] = None
    reply_to_sender_name: Optional[str] = None
    reply_to_type: Optional[str] = None
    entities: Optional[List[MentionEntityPayload]] = None  # Structured @mention entities
    bomb_duration_sec: Optional[int] = None  # Fun Pack: Time Bomb
    # 🔴 ROUND 26 — Telegram-style media albums (group chats).
    media_group_key: Optional[str] = None
    media_group_index: Optional[int] = None
    media_group_total: Optional[int] = None
    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — group key version.
    # When set, `content` is the AES-GCM ciphertext encrypted under
    # the group's symmetric key at this version. The server stores
    # the ciphertext as-is and fans `group_key_version` through to
    # every member's WS payload so they can decrypt locally via
    # GroupKeyService. Pre-fix this field didn't exist on the online
    # group-send path; iOS shipped PLAINTEXT and the server saw
    # cleartext content — violating the E2EE-everywhere directive
    # ("on device vasati nabayad befahme aslan").
    group_key_version: Optional[int] = None


class GroupMessageResponse(BaseModel):
    id: str
    group_id: str
    sender_id: str
    sender_name: str
    sender_avatar: Optional[str]
    content: str
    timestamp: datetime
    message_type: str = "text"
    audio_url: Optional[str] = None
    audio_duration_seconds: Optional[int] = None
    file_name: Optional[str] = None
    file_size: Optional[int] = None
    mime_type: Optional[str] = None
    reply_to_message_id: Optional[str] = None
    reply_to_text_preview: Optional[str] = None
    reply_to_sender_name: Optional[str] = None
    reply_to_type: Optional[str] = None
    entities: Optional[str] = None  # JSON string of mention entities
    is_duplicate: bool = False
    status: str = "accepted"
    bomb_duration_sec: Optional[int] = None  # Fun Pack: Time Bomb countdown
    poll_id: Optional[str] = None  # Fun Pack: Poll reference
    # 🔴 ROUND 26 — album passthrough
    media_group_key: Optional[str] = None
    media_group_index: Optional[int] = None
    media_group_total: Optional[int] = None
    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — receivers need
    # the AES-GCM group key version to decrypt the opaque ciphertext
    # stored in `content`. Server stores it on the GroupMessage row
    # (added by R71 p3 migration) but pre-fix the read endpoints
    # never serialized it — so clients pulling history saw the
    # ciphertext (Fernet-unwrapped to the raw GCM bytes) and the
    # bubble rendered as base64 gibberish. Pass through unchanged.
    group_key_version: Optional[int] = None

    class Config:
        from_attributes = True


@router.post("/{group_id}/messages", response_model=GroupMessageResponse)
async def send_group_message(
    group_id: str,
    req: SendGroupMessageRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Send a message to a group.
    
    - Only group members can send messages
    - Supports idempotency via message_id
    - Extracts @mention entities and creates Mention records + push notifications
    """
    # Verify group exists
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Group not found"
        )
    
    # Fun Pack: Check if group is frozen
    if group.is_frozen:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="🧊 Chat is frozen. Only an admin can unfreeze it."
        )
    
    # Verify user is a member
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    
    if not membership:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You are not a member of this group"
        )
    
    # Check for duplicate (idempotency)
    if req.message_id:
        existing = db.query(GroupMessage).filter(GroupMessage.id == req.message_id).first()
        if existing:
            print(f"⚠️ [Groups] Duplicate message {req.message_id}, returning existing")
            return GroupMessageResponse(
                id=existing.id,
                group_id=existing.group_id,
                sender_id=existing.sender_id,
                sender_name=current_user.username,
                sender_avatar=current_user.avatar_path,
                content=decrypt_text(existing.content),
                timestamp=existing.timestamp,
                message_type=existing.message_type or "text",
                audio_url=existing.audio_url,
                audio_duration_seconds=getattr(existing, 'audio_duration_seconds', None),
                file_name=existing.file_name,
                file_size=existing.file_size,
                mime_type=existing.mime_type,
                reply_to_message_id=existing.reply_to_message_id,
                reply_to_text_preview=existing.reply_to_text_preview,
                reply_to_sender_name=existing.reply_to_sender_name,
                reply_to_type=existing.reply_to_type,
                entities=existing.entities,
                is_duplicate=True,
                status="accepted",
                bomb_duration_sec=existing.bomb_duration_sec,
                poll_id=existing.poll_id,
                # 🔴 ROUND 26 — album passthrough on idempotency hit
                media_group_key=existing.media_group_key,
                media_group_index=existing.media_group_index,
                media_group_total=existing.media_group_total,
                # 🔴 ROUND 71 phase 3 follow-up — group-key version
                # on idempotency hit so a retry from the original
                # sender still knows which key the ciphertext was
                # sealed under.
                group_key_version=getattr(existing, 'group_key_version', None),
            )
    
    # Serialize entities to JSON if provided
    entities_json = None
    if req.entities:
        entities_json = json.dumps([e.dict() for e in req.entities])
    
    # Create message
    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — pass is_opaque
    # when the client supplied a group_key_version so the at-rest
    # encryption (Fernet) doesn't double-wrap the group AES-GCM
    # ciphertext. Mirrors the bridge path at messages.py:1175.
    _is_opaque = req.group_key_version is not None
    message = GroupMessage(
        id=req.message_id,  # Will use default UUID if None
        group_id=group_id,
        sender_id=current_user.id,
        content=encrypt_text(req.content, is_opaque=_is_opaque),
        timestamp=datetime.utcnow(),
        message_type=req.message_type,
        audio_url=req.audio_url,
        audio_duration_seconds=req.audio_duration_seconds,
        file_name=req.file_name,
        file_size=req.file_size,
        mime_type=req.mime_type,
        reply_to_message_id=req.reply_to_message_id,
        reply_to_text_preview=req.reply_to_text_preview,
        reply_to_sender_name=req.reply_to_sender_name,
        reply_to_type=req.reply_to_type,
        entities=entities_json,
        bomb_duration_sec=req.bomb_duration_sec,
        # 🔴 ROUND 26 — album passthrough on group send
        media_group_key=req.media_group_key,
        media_group_index=req.media_group_index,
        media_group_total=req.media_group_total,
        # 🔴 ROUND 71 phase 3 follow-up — group AES-GCM key version
        group_key_version=req.group_key_version,
    )
    
    db.add(message)
    db.commit()
    db.refresh(message)
    
    # ========== MESH DELIVERY TRACKING ==========
    # Snapshot the current member list for delivery tracking
    all_member_ids = [
        m.user_id for m in db.query(GroupMember).filter(
            GroupMember.group_id == group_id
        ).all()
    ]
    message.recipient_set = json.dumps(all_member_ids)
    message.delivered_to = json.dumps([current_user.id])  # Sender has it
    db.commit()
    
    print(f"💬 [Groups] Message sent to group {group.name} by {current_user.username}")

    # ⚡ Instant WebSocket push to all group members.
    #
    # 🔴 ROUND 71 S24: `ws_manager.notify(uid)` was called with 1 arg
    # (signature requires `(user_id, message_data)`) AND not awaited
    # → every group send raised TypeError → real-time WS fanout to
    # other members NEVER fired.
    #
    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — payload shape
    # re-shaped to mirror the bridge-group WS push so both paths
    # decode through the same iOS handler.
    #
    # 🔴 ROUND 71 phase 3 follow-up #2 (2026-05-24) — performance.
    # Fan-out moved to `asyncio.gather(..., return_exceptions=True)`
    # so the N member notifies happen concurrently instead of one-
    # after-another. The previous sequential `await` per member made
    # group send latency scale O(N * round-trip) — a 3-person group
    # waited ~600ms before the sender saw `.sent`. With gather the
    # whole fan-out finishes in ~1 round-trip.
    base_ws_msg: dict = {
        "id": message.id,
        "sender_id": current_user.id,
        "content": req.content,
        "timestamp": message.timestamp.isoformat() + "Z" if message.timestamp else None,
        "read_at": None,
        "delivered_at": None,
        "sender_username": current_user.username,
        "sender_name": current_user.username,
        "message_type": message.message_type or "text",
        "room_id": group_id,
        "audio_url": message.audio_url,
        "audio_duration_seconds": getattr(message, 'audio_duration_seconds', None),
        "file_name": message.file_name,
        "file_size": message.file_size,
        "mime_type": message.mime_type,
        "reply_to_message_id": message.reply_to_message_id,
        "reply_to_sender_name": message.reply_to_sender_name,
        "reply_to_type": message.reply_to_type,
        # 🔴 ROUND 71 phase 3 follow-up #4 (2026-05-24) — group
        # context. iOS toast renderer needs `is_group` + `group_name`
        # to compose "<sender> · <group>" in the banner title and
        # to route the message into the group thread on tap.
        "is_group": True,
        "group_id": group_id,
        "group_name": group.name,
    }
    if req.group_key_version is not None:
        base_ws_msg["group_key_version"] = req.group_key_version

    async def _push_one(target_uid: str) -> None:
        _msg = dict(base_ws_msg)
        _msg["recipient_id"] = target_uid
        try:
            await ws_manager.notify(target_uid, _msg)
        except Exception as _ws_err:
            print(f"⚠️ [Groups] WS notify failed for {target_uid[:8]}: {_ws_err}")

    import asyncio as _asyncio
    _ws_targets = [m for m in all_member_ids if m != current_user.id]
    if _ws_targets:
        await _asyncio.gather(
            *[_push_one(uid) for uid in _ws_targets],
            return_exceptions=True,
        )

    # ========== IN-APP NOTIFICATION + PUSH FOR ALL MEMBERS ==========
    #
    # 🔴 ROUND 71 phase 3 follow-up #2 (2026-05-24) — performance.
    # APNs HTTP POSTs are slow (~150-400ms each). Doing them
    # sequentially under the request handler made the sender's
    # POST return only AFTER every member's push completed —
    # user-perceived as "kheili kond" group send. Move the entire
    # in-app-notification + APNs fan-out to a background task that
    # fires after the response is returned. WS push (above) is the
    # primary delivery; notifications/APNs are secondary.
    from models import Notification
    from services.apns_service import get_apns_service, APNsService

    other_member_ids = [uid for uid in all_member_ids if uid != current_user.id]
    if other_member_ids:
        members_to_notify = db.query(User).filter(
            User.id.in_(other_member_ids)
        ).all()
        # Snapshot the User rows we need NOW (push tokens, push_platform,
        # username, preferences) so the background task doesn't touch
        # the request-scoped Session (which closes when we return).
        member_snapshots = [
            {
                "id": m.id,
                "username": m.username,
                "push_token": m.push_token,
                "push_platform": m.push_platform,
                "show_message_previews": getattr(m, "show_message_previews", True),
                "allow_message_notifications": getattr(m, "allow_message_notifications", True),
            }
            for m in members_to_notify
        ]

        sender_display = APNsService.build_push_display_name(current_user)

        if req.message_type == "text":
            preview_text = req.content[:100] if req.content else "New message"
        elif req.message_type == "voice":
            preview_text = "🎤 Voice message"
        elif req.message_type == "image":
            preview_text = "📷 Image"
        elif req.message_type == "video":
            preview_text = "🎬 Video"
        elif req.message_type == "video_note":
            preview_text = "🎥 Video note"
        elif req.message_type == "location":
            preview_text = "📍 Location"
        else:
            preview_text = "New message"
        notif_data_preview = (req.content or "")[:200]

        group_name_snapshot = group.name
        sender_id_snapshot = current_user.id
        sender_username_snapshot = current_user.username
        message_type_snapshot = req.message_type

        async def _fanout_notifications():
            from database import SessionLocal  # fresh session — request session closes when we return
            bg_db = SessionLocal()
            try:
                # 1. In-app notification rows (cheap DB inserts).
                for m in member_snapshots:
                    bg_db.add(Notification(
                        user_id=m["id"],
                        type="group_message",
                        data=json.dumps({
                            "room_id": group_id,
                            "group_id": group_id,
                            "group_name": group_name_snapshot,
                            "sender_id": sender_id_snapshot,
                            "sender_username": sender_username_snapshot,
                            "preview": notif_data_preview,
                            "message_type": message_type_snapshot,
                        }),
                        is_read=False,
                    ))
                bg_db.commit()
                # 2. APNs pushes — concurrent so the slowest one doesn't
                # block the others.
                async def _push_one_member(m: dict) -> None:
                    if not (m["push_token"] and m["push_platform"] == "ios"):
                        return
                    # Re-fetch the User row inside the bg session so
                    # APNsService.should_send_push has live preferences.
                    bg_user = bg_db.query(User).filter(User.id == m["id"]).first()
                    if not bg_user:
                        return
                    prefs = APNsService.should_send_push(bg_user, "message")
                    if not prefs["allowed"]:
                        return
                    display_preview = preview_text if prefs["show_preview"] else "New message"
                    badge = APNsService.get_unread_badge_count(bg_db, m["id"])
                    try:
                        apns = get_apns_service()
                        await apns.send_message_notification(
                            device_token=m["push_token"],
                            sender_name=f"{sender_display} in {group_name_snapshot}",
                            message_preview=display_preview,
                            room_id=group_id,
                            sender_id=sender_id_snapshot,
                            message_type=message_type_snapshot,
                            badge=badge,
                        )
                    except Exception as e:
                        print(f"📱 ❌ [Groups] Push failed for {m['username']}: {e}")
                await _asyncio.gather(
                    *[_push_one_member(m) for m in member_snapshots],
                    return_exceptions=True,
                )
                print(f"🔔 [Groups-bg] Notifications fanned out to {len(member_snapshots)} members")
            except Exception as _bg_err:
                print(f"⚠️ [Groups-bg] Notification fan-out failed: {_bg_err}")
            finally:
                bg_db.close()

        # Fire-and-forget so the sender's response returns immediately.
        _asyncio.create_task(_fanout_notifications())
    
    # ========== MENTION PROCESSING ==========
    if req.entities:
        # Get group member IDs for validation
        group_member_ids = set(
            m.user_id for m in db.query(GroupMember).filter(
                GroupMember.group_id == group_id
            ).all()
        )
        
        snippet = req.content[:80] if len(req.content) > 80 else req.content
        deep_link = f"app://chat/{group_id}?message={message.id}"
        
        # Anti-spam: max 5 mentions, dedup by userId
        seen_user_ids = set()
        mention_count = 0
        
        sender_display = APNsService.build_push_display_name(current_user)
        
        for entity in req.entities:
            if entity.type != "mention":
                continue
            if mention_count >= 5:
                print(f"⚠️ [Mentions] Max 5 mentions reached, skipping rest")
                break
            if entity.userId in seen_user_ids:
                continue  # Dedup
            if entity.userId == current_user.id:
                continue  # No self-mention notification
            if entity.userId not in group_member_ids:
                print(f"⚠️ [Mentions] User {entity.userId} not in group, skipping")
                continue
            
            seen_user_ids.add(entity.userId)
            mention_count += 1
            
            # Create Mention record
            mention = Mention(
                id=str(uuid.uuid4()),
                type="chat_message",
                source_id=message.id,
                room_id=group_id,
                mentioned_user_id=entity.userId,
                mentioned_by_user_id=current_user.id,
                created_at=datetime.utcnow(),
                snippet=snippet,
                deep_link=deep_link,
                is_read=False
            )
            db.add(mention)
            
            # Create in-app notification
            notif = Notification(
                user_id=entity.userId,
                type="mention",
                data=json.dumps({
                    "mention_type": "chat_message",
                    "group_id": group_id,
                    "group_name": group.name,
                    "message_id": message.id,
                    "mentioner_id": current_user.id,
                    "mentioner_username": current_user.username,
                    "snippet": snippet,
                    "deep_link": deep_link
                }),
                is_read=False
            )
            db.add(notif)
            print(f"🔔 [Mentions] Created mention for @{entity.username} in group {group.name}")
            
            # Send push notification (with preference check)
            mentioned_user = db.query(User).filter(User.id == entity.userId).first()
            if mentioned_user and mentioned_user.push_token and mentioned_user.push_platform == "ios":
                try:
                    from services.apns_service import get_apns_service, APNsService
                    
                    prefs = APNsService.should_send_push(mentioned_user, "mention")
                    if prefs["allowed"]:
                        apns = get_apns_service()
                        push_result = await apns.send_mention_notification(
                            device_token=mentioned_user.push_token,
                            mentioner_name=sender_display,
                            mention_type="chat_message",
                            snippet=snippet,
                            deep_link=deep_link,
                            room_id=group_id,
                            source_id=message.id,
                            group_name=group.name
                        )
                        if push_result:
                            print(f"📱 ✅ Mention push sent to @{entity.username}")
                        else:
                            print(f"📱 ❌ Mention push failed for @{entity.username}")
                    else:
                        print(f"📱 ⏭️ Mention push skipped for @{entity.username} (notifications disabled)")
                except Exception as e:
                    print(f"📱 ❌ Push error for @{entity.username}: {e}")
        
        db.commit()  # Commit all mentions + notifications
        print(f"✅ [Mentions] Processed {mention_count} mentions in group message")
    
    return GroupMessageResponse(
        id=message.id,
        group_id=message.group_id,
        sender_id=message.sender_id,
        sender_name=current_user.username,
        sender_avatar=current_user.avatar_path,
        content=decrypt_text(message.content),
        timestamp=message.timestamp,
        message_type=message.message_type or "text",
        audio_url=message.audio_url,
        audio_duration_seconds=message.audio_duration_seconds,
        file_name=message.file_name,
        file_size=message.file_size,
        mime_type=message.mime_type,
        reply_to_message_id=message.reply_to_message_id,
        reply_to_text_preview=message.reply_to_text_preview,
        reply_to_sender_name=message.reply_to_sender_name,
        reply_to_type=message.reply_to_type,
        entities=message.entities,
        is_duplicate=False,
        status="accepted",
        bomb_duration_sec=message.bomb_duration_sec,
        poll_id=message.poll_id,
        # 🔴 ROUND 26 — album passthrough on group send response
        media_group_key=message.media_group_key,
        media_group_index=message.media_group_index,
        media_group_total=message.media_group_total,
        # 🔴 ROUND 71 phase 3 follow-up — group-key version so the
        # sender's local store stamps the message row correctly on
        # the POST ACK round-trip (mirrors WS push at line 829).
        group_key_version=getattr(message, 'group_key_version', None),
    )


# ═══════════════════════════════════════════════════════════════════════════
# GROUP MESSAGE ACK (Mesh delivery tracking)
# ═══════════════════════════════════════════════════════════════════════════

class GroupMessageACKResponse(BaseModel):
    """Response for group message ACK — tells client whether to cancel mesh."""
    message_id: str
    cancel_mesh: bool
    delivered_count: int
    total_count: int

@router.post("/{group_id}/messages/{message_id}/ack", response_model=GroupMessageACKResponse)
async def ack_group_message(
    group_id: str,
    message_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    ACK receipt of a group message.
    
    Called by group members when they receive the message (via server or mesh).
    Returns cancel_mesh=true when all members have received the message.
    """
    # Verify group membership
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Not a member of this group"
        )
    
    # Find the message
    msg = db.query(GroupMessage).filter(
        GroupMessage.id == message_id,
        GroupMessage.group_id == group_id
    ).first()
    if not msg:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Message not found"
        )
    
    # Update delivered_to set
    delivered = json.loads(msg.delivered_to or "[]")
    if current_user.id not in delivered:
        delivered.append(current_user.id)
        msg.delivered_to = json.dumps(delivered)
        db.commit()
        print(f"✅ [Groups ACK] {current_user.username} ACKed message {message_id[:8]} in group {group_id[:8]} ({len(delivered)} delivered)")
    
    # Check if fully delivered
    recipients = json.loads(msg.recipient_set or "[]")
    fully_delivered = set(delivered) >= set(recipients) if recipients else False
    
    if fully_delivered:
        print(f"🛑 [Groups ACK] All {len(recipients)} members received message {message_id[:8]} — cancel_mesh=true")
    
    return GroupMessageACKResponse(
        message_id=message_id,
        cancel_mesh=fully_delivered,
        delivered_count=len(delivered),
        total_count=len(recipients)
    )


@router.get("/{group_id}/messages", response_model=List[GroupMessageResponse])
def get_group_messages(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    since: Optional[str] = None,
    limit: int = 100
):
    """
    Get messages from a group.
    
    - Only group members can read messages
    - Optional 'since' param for incremental sync
    """
    try:
        # Verify group exists
        group = db.query(Group).filter(Group.id == group_id).first()
        if not group:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Group not found"
            )
        
        # Verify user is a member
        membership = db.query(GroupMember).filter(
            GroupMember.group_id == group_id,
            GroupMember.user_id == current_user.id
        ).first()
        
        if not membership:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You are not a member of this group"
            )
        
        # Build query
        query = db.query(GroupMessage).filter(GroupMessage.group_id == group_id)
        
        if since:
            try:
                since_dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
                query = query.filter(GroupMessage.timestamp > since_dt)
            except ValueError:
                pass
        
        messages = query.order_by(GroupMessage.timestamp.asc()).limit(limit).all()
        
        print(f"📬 [Groups] Fetched {len(messages)} messages for group {group_id}")
        
        # ⚡ Batch sender lookup instead of per-message query
        sender_ids = set(msg.sender_id for msg in messages)
        senders = {u.id: u for u in db.query(User).filter(User.id.in_(sender_ids)).all()} if sender_ids else {}
        
        responses = []
        for msg in messages:
            sender = senders.get(msg.sender_id)
            # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — if the
            # message was stored opaque (`group_key_version is not
            # None`), the Fernet wrap on disk is wrapping the GCM
            # ciphertext; `decrypt_text` strips that and gives us
            # back the base64 GCM blob the client encrypted. Pass
            # the version through so the client knows which key to
            # use to AES-GCM-decrypt. Without this passthrough the
            # client received the ciphertext but had no idea it was
            # group-sealed → bubble rendered raw base64.
            _gkv = getattr(msg, 'group_key_version', None)
            responses.append(GroupMessageResponse(
                id=msg.id,
                group_id=msg.group_id,
                sender_id=msg.sender_id,
                sender_name=sender.username if sender else "Unknown",
                sender_avatar=sender.avatar_path if sender else None,
                content=decrypt_text(msg.content) or "",
                timestamp=msg.timestamp,
                message_type=msg.message_type or "text",
                audio_url=msg.audio_url,
                audio_duration_seconds=getattr(msg, 'audio_duration_seconds', None),
                file_name=msg.file_name,
                file_size=msg.file_size,
                mime_type=msg.mime_type,
                reply_to_message_id=msg.reply_to_message_id,
                reply_to_text_preview=msg.reply_to_text_preview,
                reply_to_sender_name=msg.reply_to_sender_name,
                reply_to_type=msg.reply_to_type,
                entities=msg.entities,
                status="accepted",
                bomb_duration_sec=msg.bomb_duration_sec,
                poll_id=msg.poll_id,
                # 🔴 ROUND 26 — album passthrough on group history
                media_group_key=msg.media_group_key,
                media_group_index=msg.media_group_index,
                media_group_total=msg.media_group_total,
                # 🔴 ROUND 71 phase 3 follow-up — group-key version.
                group_key_version=_gkv,
            ))
        
        return responses
    except HTTPException:
        raise  # Re-raise HTTP exceptions as-is
    except Exception as e:
        import traceback
        print(f"🚨 [Groups] get_group_messages FAILED for group {group_id}: {type(e).__name__}: {e}")
        traceback.print_exc()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Internal server error: {type(e).__name__}: {str(e)}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# ADMIN MANAGEMENT ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════

def _require_admin(db: Session, group_id: str, user_id: str) -> GroupMember:
    """Helper: verify user is admin of the group. Returns membership or raises 403."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == user_id
    ).first()
    if not membership:
        raise HTTPException(status_code=404, detail="You are not a member of this group")
    if membership.role != "admin":
        raise HTTPException(status_code=403, detail="Only admins can perform this action")
    return membership


@router.post("/{group_id}/members/{user_id}/kick")
async def kick_member(
    group_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Kick a member from the group (admin only)."""
    _require_admin(db, group_id, current_user.id)
    
    if user_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot kick yourself. Use leave instead.")
    
    target = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == user_id
    ).first()
    if not target:
        raise HTTPException(status_code=404, detail="User is not a member of this group")
    
    target_user = db.query(User).filter(User.id == user_id).first()
    target_name = target_user.username if target_user else "Unknown"

    db.delete(target)

    # System message
    sys_msg = GroupMessage(
        id=str(uuid.uuid4()),
        group_id=group_id,
        sender_id=current_user.id,
        content=encrypt_text(f"{target_name} was removed by {current_user.username}"),
        message_type="system",
        timestamp=datetime.utcnow()
    )
    db.add(sys_msg)

    # 🔴 hacker-audit 2026-05-19 — forward secrecy on kick.
    #
    # group_keys.py's module docstring advertises "Forward secrecy on
    # member-kick: bumping the version means a kicked member's cached
    # key can't decrypt new messages." But the kick endpoint never
    # actually called the key-rotation primitive — it only deleted the
    # membership row. A kicked member's cached group_key (last fetched
    # from GET /api/groups/{id}/key while still a member) thus stayed
    # valid forever. Combined with the BLE-mesh broadcast architecture
    # (any device in radio range hears every encrypted envelope), a
    # kicked member could sit silently in radio range and keep reading
    # every group message until an admin remembered to manually call
    # POST /api/groups/{id}/key/rotate — which they almost never do.
    #
    # Server-side broadcast WS payloads also remain decryptable by the
    # cached key, so the LAN/BLE caveat isn't even required for the
    # attack to land.
    #
    # FIX: every kick mints a new key version atomically with the
    # membership delete. Remaining members re-fetch on next GET /key
    # (or on cache-miss when they receive a v+1 envelope they can't
    # decrypt with v).
    new_key_version = None
    try:
        from routers.group_keys import _mint_new_key
        new_key = _mint_new_key(db, group_id)
        new_key_version = getattr(new_key, "version", None) if new_key else None
    except Exception as _key_err:
        # Don't fail the kick if key minting somehow errors — log
        # loudly so ops notices. The membership delete is the
        # primary security boundary; key rotation is defence in
        # depth on top of it.
        print(f"⚠️ [Groups] kick: group-key rotation failed for {group_id}: {_key_err}")

    db.commit()

    # 🔴 ROUND 71 S23: WS-push `group_key_rotated` to all REMAINING
    # members so each iOS client invalidates its `latest` cache and
    # re-fetches the new version on the very next encrypt. Without
    # this, remaining members kept encrypting with v(N-1) until they
    # personally received a v+1 envelope they couldn't decrypt with v
    # — meanwhile the kicked member (still cached v(N-1) and in BLE
    # range) decrypted every supposedly-rotated message.
    try:
        remaining = db.query(GroupMember).filter(
            GroupMember.group_id == group_id,
            GroupMember.user_id != user_id,
        ).all()
        for _m in remaining:
            try:
                await ws_manager.notify(_m.user_id, {
                    "type": "group_key_rotated",
                    "group_id": group_id,
                    "version": new_key_version,
                })
            except Exception:
                pass
    except Exception as _push_err:
        print(f"⚠️ [Groups] kick: key-rotation WS push failed: {_push_err}")

    print(f"🦶 [Groups] {current_user.username} kicked {target_name} from {group_id} "
          f"(key rotated → v{new_key_version})")
    return {
        "success": True,
        "message": f"{target_name} removed from group",
        "new_key_version": new_key_version,
    }


@router.post("/{group_id}/members/{user_id}/promote")
def promote_member(
    group_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Promote a member to admin (admin only)."""
    _require_admin(db, group_id, current_user.id)
    
    target = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == user_id
    ).first()
    if not target:
        raise HTTPException(status_code=404, detail="User is not a member of this group")
    if target.role == "admin":
        raise HTTPException(status_code=400, detail="User is already an admin")
    
    target.role = "admin"
    db.commit()
    
    target_user = db.query(User).filter(User.id == user_id).first()
    print(f"⬆️ [Groups] Promoted {target_user.username if target_user else user_id} to admin in {group_id}")
    return {"success": True, "message": "User promoted to admin"}


@router.post("/{group_id}/members/{user_id}/demote")
def demote_member(
    group_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Demote an admin to member (admin only). Cannot demote the last admin."""
    _require_admin(db, group_id, current_user.id)
    
    target = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == user_id
    ).first()
    if not target:
        raise HTTPException(status_code=404, detail="User is not a member of this group")
    if target.role != "admin":
        raise HTTPException(status_code=400, detail="User is not an admin")
    
    # Don't allow demoting if this would leave the group with no admins
    admin_count = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.role == "admin"
    ).count()
    if admin_count <= 1:
        raise HTTPException(status_code=400, detail="Cannot demote the last admin. Promote another member first.")
    
    target.role = "member"
    db.commit()
    
    target_user = db.query(User).filter(User.id == user_id).first()
    print(f"⬇️ [Groups] Demoted {target_user.username if target_user else user_id} from admin in {group_id}")
    return {"success": True, "message": "User demoted to member"}


@router.patch("/{group_id}")
def update_group(
    group_id: str,
    req: UpdateGroupRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Update group info (admin only). Supports name, avatar, description, visibility, link_join_enabled."""
    _require_admin(db, group_id, current_user.id)
    
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        raise HTTPException(status_code=404, detail="Group not found")
    
    if req.name is not None:
        name = req.name.strip()
        if len(name) < 2 or len(name) > 40:
            raise HTTPException(status_code=400, detail="Name must be 2-40 characters")
        group.name = name
    if req.avatar_url is not None:
        group.avatar_url = req.avatar_url
    if req.description is not None:
        group.description = req.description
    if req.visibility is not None:
        if req.visibility not in ("public", "private"):
            raise HTTPException(status_code=400, detail="Visibility must be 'public' or 'private'")
        group.visibility = req.visibility
    if req.link_join_enabled is not None:
        group.link_join_enabled = req.link_join_enabled
    
    db.commit()
    print(f"✏️ [Groups] Updated group {group_id} by {current_user.username}")
    return {"success": True, "message": "Group updated"}


# ═══════════════════════════════════════════════════════════════════════════
# INVITE LINK ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════

@router.post("/{group_id}/invite-link")
def create_or_get_invite_link(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Create or get existing invite link for a group (admin only)."""
    _require_admin(db, group_id, current_user.id)
    
    # Check if link already exists
    existing = db.query(GroupInviteLink).filter(
        GroupInviteLink.group_id == group_id,
        GroupInviteLink.enabled == True
    ).first()
    
    if existing:
        return InviteLinkResponse(
            invite_code=existing.invite_code,
            group_id=existing.group_id,
            created_by=existing.created_by,
            enabled=existing.enabled,
            use_count=existing.use_count,
            max_uses=existing.max_uses,
            expires_at=existing.expires_at
        )
    
    # Create new link
    code = secrets.token_urlsafe(12)  # ~16 chars, URL-safe
    link = GroupInviteLink(
        id=str(uuid.uuid4()),
        group_id=group_id,
        invite_code=code,
        created_by=current_user.id,
        enabled=True,
        use_count=0
    )
    db.add(link)
    db.commit()
    
    print(f"🔗 [Groups] Created invite link for {group_id} by {current_user.username}")
    return InviteLinkResponse(
        invite_code=link.invite_code,
        group_id=link.group_id,
        created_by=link.created_by,
        enabled=link.enabled,
        use_count=link.use_count,
        max_uses=link.max_uses,
        expires_at=link.expires_at
    )


@router.delete("/{group_id}/invite-link")
def reset_invite_link(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Reset/revoke the invite link for a group (admin only). Old links stop working."""
    _require_admin(db, group_id, current_user.id)
    
    # Disable all existing links
    db.query(GroupInviteLink).filter(
        GroupInviteLink.group_id == group_id
    ).delete()
    db.commit()
    
    print(f"🔄 [Groups] Reset invite link for {group_id} by {current_user.username}")
    return {"success": True, "message": "Invite link revoked"}


@router.post("/join/{invite_code}")
def join_via_invite(
    invite_code: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Join a group using an invite code."""
    link = db.query(GroupInviteLink).filter(
        GroupInviteLink.invite_code == invite_code,
        GroupInviteLink.enabled == True
    ).first()
    
    if not link:
        raise HTTPException(status_code=404, detail="Invalid or expired invite link")
    
    # Check expiry
    if link.expires_at and link.expires_at < datetime.utcnow():
        raise HTTPException(status_code=410, detail="Invite link has expired")
    
    # Check max uses
    if link.max_uses and link.use_count >= link.max_uses:
        raise HTTPException(status_code=410, detail="Invite link has reached maximum uses")
    
    # Check if group join via link is enabled
    group = db.query(Group).filter(Group.id == link.group_id).first()
    if not group:
        raise HTTPException(status_code=404, detail="Group no longer exists")
    if not group.link_join_enabled:
        raise HTTPException(status_code=403, detail="This group does not allow joining via link")
    
    # Check if already a member
    existing = db.query(GroupMember).filter(
        GroupMember.group_id == link.group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if existing:
        raise HTTPException(status_code=400, detail="You are already a member of this group")
    
    # Add as member
    new_member = GroupMember(
        id=str(uuid.uuid4()),
        group_id=link.group_id,
        user_id=current_user.id,
        role="member",
        joined_at=datetime.utcnow()
    )
    db.add(new_member)
    
    # Increment use count
    link.use_count += 1
    
    # System message
    sys_msg = GroupMessage(
        id=str(uuid.uuid4()),
        group_id=link.group_id,
        sender_id=current_user.id,
        content=encrypt_text(f"{current_user.username} joined via invite link"),
        message_type="system",
        timestamp=datetime.utcnow()
    )
    db.add(sys_msg)
    db.commit()
    
    print(f"🎉 [Groups] {current_user.username} joined {link.group_id} via invite link")
    
    # Return group details
    member_count = db.query(GroupMember).filter(GroupMember.group_id == link.group_id).count()
    return {
        "success": True,
        "group_id": link.group_id,
        "group_name": group.name,
        "member_count": member_count
    }


# ═══════════════════════════════════════════════════════════════════════════
# FUN PACK: GROUP POLLS
# ═══════════════════════════════════════════════════════════════════════════

class CreatePollRequest(BaseModel):
    question: str
    options: List[str]  # 2-10 option texts
    allow_multiple: bool = False
    is_anonymous: bool = False
    expires_in_minutes: Optional[int] = None  # Auto-close after N minutes

class PollOptionResponse(BaseModel):
    id: str
    text: str
    vote_count: int
    voters: List[str] = []  # usernames (empty if anonymous)
    
    class Config:
        from_attributes = True

class PollResponse(BaseModel):
    id: str
    group_id: str
    creator_id: str
    creator_name: str
    question: str
    options: List[PollOptionResponse]
    allow_multiple: bool
    is_anonymous: bool
    is_closed: bool
    total_votes: int
    my_votes: List[str] = []  # option IDs I voted for
    created_at: datetime
    expires_at: Optional[datetime] = None
    
    class Config:
        from_attributes = True

class VoteRequest(BaseModel):
    option_id: str


def _build_poll_response(poll: GroupPoll, current_user_id: str, db: Session) -> PollResponse:
    """Helper to build a PollResponse with vote data."""
    creator = db.query(User).filter(User.id == poll.creator_id).first()
    
    options = []
    for opt in poll.options:
        voters = []
        if not poll.is_anonymous:
            vote_records = db.query(GroupPollVote).filter(GroupPollVote.option_id == opt.id).all()
            for v in vote_records:
                voter = db.query(User).filter(User.id == v.user_id).first()
                if voter:
                    voters.append(voter.username)
        options.append(PollOptionResponse(
            id=opt.id,
            text=opt.text,
            vote_count=opt.vote_count,
            voters=voters
        ))
    
    my_votes = [
        v.option_id for v in db.query(GroupPollVote).filter(
            GroupPollVote.poll_id == poll.id,
            GroupPollVote.user_id == current_user_id
        ).all()
    ]
    
    total_votes = sum(o.vote_count for o in poll.options)
    
    return PollResponse(
        id=poll.id,
        group_id=poll.group_id,
        creator_id=poll.creator_id,
        creator_name=creator.username if creator else "Unknown",
        question=poll.question,
        options=options,
        allow_multiple=poll.allow_multiple,
        is_anonymous=poll.is_anonymous,
        is_closed=poll.is_closed,
        total_votes=total_votes,
        my_votes=my_votes,
        created_at=poll.created_at,
        expires_at=poll.expires_at
    )


@router.post("/{group_id}/polls", response_model=PollResponse)
def create_poll(
    group_id: str,
    req: CreatePollRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Create a new poll in a group chat."""
    # Validate
    if len(req.options) < 2:
        raise HTTPException(status_code=400, detail="Poll must have at least 2 options")
    if len(req.options) > 10:
        raise HTTPException(status_code=400, detail="Poll can have at most 10 options")
    if not req.question.strip():
        raise HTTPException(status_code=400, detail="Question is required")
    
    # Verify membership
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this group")
    
    from datetime import timedelta
    expires_at = None
    if req.expires_in_minutes:
        expires_at = datetime.utcnow() + timedelta(minutes=req.expires_in_minutes)
    
    poll = GroupPoll(
        group_id=group_id,
        creator_id=current_user.id,
        question=req.question.strip(),
        allow_multiple=req.allow_multiple,
        is_anonymous=req.is_anonymous,
        expires_at=expires_at
    )
    db.add(poll)
    db.flush()
    
    for idx, opt_text in enumerate(req.options):
        option = GroupPollOption(
            poll_id=poll.id,
            text=opt_text.strip(),
            order_index=idx
        )
        db.add(option)
    
    # Also send a system message announcing the poll
    sys_msg = GroupMessage(
        id=str(uuid.uuid4()),
        group_id=group_id,
        sender_id=current_user.id,
        content=encrypt_text(f"📊 {current_user.username} created a poll: {req.question.strip()}"),
        message_type="poll",
        poll_id=poll.id,
        timestamp=datetime.utcnow()
    )
    db.add(sys_msg)
    
    db.commit()
    db.refresh(poll)
    
    print(f"📊 [Fun Pack] Poll created in group {group_id} by {current_user.username}: {req.question[:50]}")
    return _build_poll_response(poll, current_user.id, db)


@router.get("/{group_id}/polls", response_model=List[PollResponse])
def list_polls(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """List all polls in a group (most recent first)."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this group")
    
    polls = db.query(GroupPoll).filter(
        GroupPoll.group_id == group_id
    ).order_by(GroupPoll.created_at.desc()).limit(50).all()
    
    return [_build_poll_response(p, current_user.id, db) for p in polls]


@router.get("/{group_id}/polls/{poll_id}", response_model=PollResponse)
def get_poll(
    group_id: str,
    poll_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get poll details with current vote counts."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this group")
    
    poll = db.query(GroupPoll).filter(GroupPoll.id == poll_id, GroupPoll.group_id == group_id).first()
    if not poll:
        raise HTTPException(status_code=404, detail="Poll not found")
    
    return _build_poll_response(poll, current_user.id, db)


@router.post("/{group_id}/polls/{poll_id}/vote", response_model=PollResponse)
def vote_on_poll(
    group_id: str,
    poll_id: str,
    req: VoteRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Cast a vote on a poll option. Toggle: voting again removes the vote."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this group")
    
    poll = db.query(GroupPoll).filter(GroupPoll.id == poll_id, GroupPoll.group_id == group_id).first()
    if not poll:
        raise HTTPException(status_code=404, detail="Poll not found")
    if poll.is_closed:
        raise HTTPException(status_code=400, detail="Poll is closed")
    if poll.expires_at and poll.expires_at < datetime.utcnow():
        poll.is_closed = True
        db.commit()
        raise HTTPException(status_code=400, detail="Poll has expired")
    
    option = db.query(GroupPollOption).filter(
        GroupPollOption.id == req.option_id,
        GroupPollOption.poll_id == poll_id
    ).first()
    if not option:
        raise HTTPException(status_code=404, detail="Option not found")
    
    # Check if already voted for this option (toggle off)
    existing_vote = db.query(GroupPollVote).filter(
        GroupPollVote.poll_id == poll_id,
        GroupPollVote.option_id == req.option_id,
        GroupPollVote.user_id == current_user.id
    ).first()
    
    if existing_vote:
        # Toggle off: remove vote
        db.delete(existing_vote)
        option.vote_count = max(0, option.vote_count - 1)
        db.commit()
        print(f"📊 [Fun Pack] Vote removed by {current_user.username} on poll {poll_id}")
    else:
        # If not allow_multiple, remove any existing votes first
        if not poll.allow_multiple:
            old_votes = db.query(GroupPollVote).filter(
                GroupPollVote.poll_id == poll_id,
                GroupPollVote.user_id == current_user.id
            ).all()
            for old_vote in old_votes:
                old_opt = db.query(GroupPollOption).filter(GroupPollOption.id == old_vote.option_id).first()
                if old_opt:
                    old_opt.vote_count = max(0, old_opt.vote_count - 1)
                db.delete(old_vote)
        
        # Cast new vote
        vote = GroupPollVote(
            poll_id=poll_id,
            option_id=req.option_id,
            user_id=current_user.id
        )
        db.add(vote)
        option.vote_count += 1
        db.commit()
        print(f"📊 [Fun Pack] Vote cast by {current_user.username} on poll {poll_id}")
    
    db.refresh(poll)
    return _build_poll_response(poll, current_user.id, db)


@router.post("/{group_id}/polls/{poll_id}/close", response_model=PollResponse)
def close_poll(
    group_id: str,
    poll_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Close a poll (creator or admin only)."""
    poll = db.query(GroupPoll).filter(GroupPoll.id == poll_id, GroupPoll.group_id == group_id).first()
    if not poll:
        raise HTTPException(status_code=404, detail="Poll not found")
    
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    if poll.creator_id != current_user.id and membership.role != "admin":
        raise HTTPException(status_code=403, detail="Only poll creator or admin can close a poll")
    
    poll.is_closed = True
    db.commit()
    db.refresh(poll)
    
    print(f"📊 [Fun Pack] Poll {poll_id} closed by {current_user.username}")
    return _build_poll_response(poll, current_user.id, db)


# ═══════════════════════════════════════════════════════════════════════════
# FUN PACK: FREEZE MODE
# ═══════════════════════════════════════════════════════════════════════════

@router.post("/{group_id}/freeze")
def toggle_freeze(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Toggle freeze/unfreeze for a group (admin only)."""
    _require_admin(db, group_id, current_user.id)
    
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        raise HTTPException(status_code=404, detail="Group not found")
    
    if group.is_frozen:
        # Unfreeze
        group.is_frozen = False
        group.frozen_by = None
        group.frozen_at = None
        action = "unfrozen"
        emoji = "🔥"
    else:
        # Freeze
        group.is_frozen = True
        group.frozen_by = current_user.id
        group.frozen_at = datetime.utcnow()
        action = "frozen"
        emoji = "🧊"
    
    # System message
    sys_msg = GroupMessage(
        id=str(uuid.uuid4()),
        group_id=group_id,
        sender_id=current_user.id,
        content=encrypt_text(f"{emoji} {current_user.username} {action} the chat"),
        message_type="system",
        timestamp=datetime.utcnow()
    )
    db.add(sys_msg)
    db.commit()
    
    print(f"{emoji} [Fun Pack] Group {group_id} {action} by {current_user.username}")
    return {
        "success": True,
        "is_frozen": group.is_frozen,
        "frozen_by": group.frozen_by,
        "message": f"Chat {action}"
    }


# ═══════════════════════════════════════════════════════════════════════════
# FUN PACK: GROUP MASKS (ANONYMOUS MODE)
# ═══════════════════════════════════════════════════════════════════════════

MASK_POOL = [
    ("Shadow Fox", "🦊"), ("Ghost Panda", "🐼"), ("Neon Wolf", "🐺"),
    ("Crystal Owl", "🦉"), ("Velvet Cat", "🐱"), ("Storm Eagle", "🦅"),
    ("Cyber Bear", "🐻"), ("Mystic Deer", "🦌"), ("Dark Phoenix", "🔥"),
    ("Lunar Rabbit", "🐰"), ("Iron Tiger", "🐯"), ("Silent Snake", "🐍"),
    ("Frost Dragon", "🐉"), ("Crimson Bat", "🦇"), ("Jade Turtle", "🐢"),
    ("Thunder Gorilla", "🦍"), ("Prism Peacock", "🦚"), ("Smoke Panther", "🐆"),
    ("Blaze Unicorn", "🦄"), ("Ocean Dolphin", "🐬")
]

class MaskResponse(BaseModel):
    id: str
    mask_name: str
    mask_emoji: str
    is_active: bool
    assigned_at: datetime
    
    class Config:
        from_attributes = True


@router.post("/{group_id}/masks/activate", response_model=MaskResponse)
def activate_mask(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Activate a random anonymous mask for the current user in this group."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    
    # Check if already has a mask
    existing = db.query(GroupMask).filter(
        GroupMask.group_id == group_id,
        GroupMask.user_id == current_user.id
    ).first()
    if existing and existing.is_active:
        return MaskResponse(
            id=existing.id,
            mask_name=existing.mask_name,
            mask_emoji=existing.mask_emoji,
            is_active=existing.is_active,
            assigned_at=existing.assigned_at
        )
    
    # Get masks already in use in this group
    used_masks = set(
        m.mask_name for m in db.query(GroupMask).filter(
            GroupMask.group_id == group_id,
            GroupMask.is_active == True
        ).all()
    )
    
    import random
    available = [(n, e) for n, e in MASK_POOL if n not in used_masks]
    if not available:
        available = MASK_POOL  # All used — allow duplicates
    
    name, emoji = random.choice(available)
    
    if existing:
        existing.mask_name = name
        existing.mask_emoji = emoji
        existing.is_active = True
        existing.assigned_at = datetime.utcnow()
        db.commit()
        db.refresh(existing)
        mask = existing
    else:
        mask = GroupMask(
            group_id=group_id,
            user_id=current_user.id,
            mask_name=name,
            mask_emoji=emoji
        )
        db.add(mask)
        db.commit()
        db.refresh(mask)
    
    # System message
    sys_msg = GroupMessage(
        id=str(uuid.uuid4()),
        group_id=group_id,
        sender_id=current_user.id,
        content=encrypt_text(f"🎭 Someone put on a mask: {emoji} {name}"),
        message_type="system",
        timestamp=datetime.utcnow()
    )
    db.add(sys_msg)
    db.commit()
    
    print(f"🎭 [Fun Pack] Mask activated in group {group_id}: {emoji} {name}")
    return MaskResponse(
        id=mask.id,
        mask_name=mask.mask_name,
        mask_emoji=mask.mask_emoji,
        is_active=mask.is_active,
        assigned_at=mask.assigned_at
    )


@router.delete("/{group_id}/masks")
def deactivate_mask(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Remove your mask and go back to real identity."""
    mask = db.query(GroupMask).filter(
        GroupMask.group_id == group_id,
        GroupMask.user_id == current_user.id
    ).first()
    if not mask:
        raise HTTPException(status_code=404, detail="No active mask")
    
    mask.is_active = False
    db.commit()
    
    print(f"🎭 [Fun Pack] Mask deactivated in group {group_id} by {current_user.username}")
    return {"success": True, "message": "Mask removed"}


@router.get("/{group_id}/masks", response_model=List[MaskResponse])
def list_active_masks(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """List all active masks in the group."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    
    masks = db.query(GroupMask).filter(
        GroupMask.group_id == group_id,
        GroupMask.is_active == True
    ).all()
    
    return [
        MaskResponse(
            id=m.id,
            mask_name=m.mask_name,
            mask_emoji=m.mask_emoji,
            is_active=m.is_active,
            assigned_at=m.assigned_at
        ) for m in masks
    ]


@router.get("/{group_id}/masks/me", response_model=Optional[MaskResponse])
def get_my_mask(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get the current user's active mask in this group."""
    mask = db.query(GroupMask).filter(
        GroupMask.group_id == group_id,
        GroupMask.user_id == current_user.id,
        GroupMask.is_active == True
    ).first()
    if not mask:
        return None
    return MaskResponse(
        id=mask.id,
        mask_name=mask.mask_name,
        mask_emoji=mask.mask_emoji,
        is_active=mask.is_active,
        assigned_at=mask.assigned_at
    )


# ═══════════════════════════════════════════════════════════════════════════
# FUN PACK: AI ROAST / HYPE
# ═══════════════════════════════════════════════════════════════════════════

class AIRoastRequest(BaseModel):
    target_user_id: str
    mode: str = "roast"  # "roast" or "hype"


@router.post("/{group_id}/ai-roast")
async def ai_roast(
    group_id: str,
    req: AIRoastRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Generate an AI roast or compliment for a group member."""
    # Verify membership
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    
    # Verify target is also a member
    target_membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == req.target_user_id
    ).first()
    if not target_membership:
        raise HTTPException(status_code=404, detail="Target user is not a member")
    
    target_user = db.query(User).filter(User.id == req.target_user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="Target user not found")
    
    # Get last 20 messages from target in this group for context
    recent_messages = db.query(GroupMessage).filter(
        GroupMessage.group_id == group_id,
        GroupMessage.sender_id == req.target_user_id,
        GroupMessage.message_type == "text"
    ).order_by(GroupMessage.timestamp.desc()).limit(20).all()
    
    message_texts = []
    for msg in recent_messages:
        decrypted = decrypt_text(msg.content)
        if decrypted and decrypted != "[DECRYPT_FAILED]":
            message_texts.append(decrypted)
    
    context = "\n".join(message_texts[:10]) if message_texts else "No recent messages"
    
    mode_label = "roast" if req.mode == "roast" else "hype"
    mode_emoji = "🔥" if req.mode == "roast" else "💎"
    
    # Build prompt
    if req.mode == "roast":
        prompt = f"""You are a witty comedian in a group chat. Generate a short, funny, LIGHT-HEARTED roast 
(max 2 sentences) for the user '{target_user.username}'. Keep it PG-13, nothing offensive or hurtful. 
Make it silly and fun. Their recent messages for context:\n{context}"""
    else:
        prompt = f"""You are a hype master in a group chat. Generate a short, enthusiastic compliment 
(max 2 sentences) for the user '{target_user.username}'. Make it feel genuine and fun. 
Their recent messages for context:\n{context}"""
    
    # Use Gemini
    from services.gemini_service import get_gemini_service
    gemini = get_gemini_service()
    if not gemini:
        raise HTTPException(status_code=503, detail="AI service not available")
    
    try:
        result = await gemini.generate_response(
            question=prompt,
            post_content="",
            thread_history=[],
            language="en",
            enable_search=False
        )
        ai_text = result.get("response", "I got nothing 😅")
    except Exception as e:
        print(f"❌ [Fun Pack] AI roast failed: {e}")
        ai_text = "The AI is speechless... which is rare 😅"
    
    # Send as system message
    sys_msg = GroupMessage(
        id=str(uuid.uuid4()),
        group_id=group_id,
        sender_id=current_user.id,
        content=encrypt_text(f"{mode_emoji} AI {mode_label} for @{target_user.username}:\n{ai_text}"),
        message_type="system",
        timestamp=datetime.utcnow()
    )
    db.add(sys_msg)
    db.commit()
    
    print(f"{mode_emoji} [Fun Pack] AI {mode_label} for {target_user.username} in group {group_id}")
    return {
        "response": ai_text,
        "target_user_id": req.target_user_id,
        "target_username": target_user.username,
        "mode": req.mode
    }


# ═══════════════════════════════════════════════════════════════════════════
# FUN PACK: VOICE CHAINS
# ═══════════════════════════════════════════════════════════════════════════

class CreateChainRequest(BaseModel):
    title: str
    max_duration_sec: int = 15  # Max seconds per link

class ChainLinkResponse(BaseModel):
    id: str
    user_id: str
    username: str
    audio_url: str
    duration_sec: int
    order_index: int
    created_at: datetime
    
    class Config:
        from_attributes = True

class ChainResponse(BaseModel):
    id: str
    group_id: str
    creator_id: str
    creator_name: str
    title: str
    max_duration_sec: int
    status: str
    links: List[ChainLinkResponse]
    total_duration_sec: int
    created_at: datetime
    
    class Config:
        from_attributes = True

class AddChainLinkRequest(BaseModel):
    audio_url: str
    duration_sec: int


@router.post("/{group_id}/voice-chains", response_model=ChainResponse)
def create_voice_chain(
    group_id: str,
    req: CreateChainRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Start a new voice chain in the group."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    
    # Check for existing open chain
    existing = db.query(VoiceChain).filter(
        VoiceChain.group_id == group_id,
        VoiceChain.status == "open"
    ).first()
    if existing:
        raise HTTPException(status_code=400, detail="There's already an open voice chain. Close it first.")
    
    chain = VoiceChain(
        group_id=group_id,
        creator_id=current_user.id,
        title=req.title.strip(),
        max_duration_sec=min(req.max_duration_sec, 30)  # Cap at 30s
    )
    db.add(chain)
    db.commit()
    db.refresh(chain)
    
    # System message
    sys_msg = GroupMessage(
        id=str(uuid.uuid4()),
        group_id=group_id,
        sender_id=current_user.id,
        content=encrypt_text(f"🎙️ {current_user.username} started a voice chain: {req.title.strip()}"),
        message_type="system",
        timestamp=datetime.utcnow()
    )
    db.add(sys_msg)
    db.commit()
    
    print(f"🎙️ [Fun Pack] Voice chain started in group {group_id}: {req.title}")
    return ChainResponse(
        id=chain.id,
        group_id=chain.group_id,
        creator_id=chain.creator_id,
        creator_name=current_user.username,
        title=chain.title,
        max_duration_sec=chain.max_duration_sec,
        status=chain.status,
        links=[],
        total_duration_sec=0,
        created_at=chain.created_at
    )


@router.post("/{group_id}/voice-chains/{chain_id}/add", response_model=ChainResponse)
def add_chain_link(
    group_id: str,
    chain_id: str,
    req: AddChainLinkRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Add your voice clip to the chain (one per user)."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    
    chain = db.query(VoiceChain).filter(
        VoiceChain.id == chain_id,
        VoiceChain.group_id == group_id
    ).first()
    if not chain:
        raise HTTPException(status_code=404, detail="Voice chain not found")
    if chain.status != "open":
        raise HTTPException(status_code=400, detail="This voice chain is closed")
    
    # Check if already contributed
    existing_link = db.query(VoiceChainLink).filter(
        VoiceChainLink.chain_id == chain_id,
        VoiceChainLink.user_id == current_user.id
    ).first()
    if existing_link:
        raise HTTPException(status_code=400, detail="You already added your clip to this chain")
    
    # Check duration
    if req.duration_sec > chain.max_duration_sec:
        raise HTTPException(status_code=400, detail=f"Clip must be {chain.max_duration_sec}s or less")
    
    # Get next order index
    max_order = db.query(VoiceChainLink).filter(
        VoiceChainLink.chain_id == chain_id
    ).count()
    
    link = VoiceChainLink(
        chain_id=chain_id,
        user_id=current_user.id,
        audio_url=req.audio_url,
        duration_sec=req.duration_sec,
        order_index=max_order
    )
    db.add(link)
    db.commit()
    db.refresh(chain)
    
    # Build response
    links = []
    total_dur = 0
    for lnk in chain.links:
        user = db.query(User).filter(User.id == lnk.user_id).first()
        links.append(ChainLinkResponse(
            id=lnk.id,
            user_id=lnk.user_id,
            username=user.username if user else "Unknown",
            audio_url=lnk.audio_url,
            duration_sec=lnk.duration_sec,
            order_index=lnk.order_index,
            created_at=lnk.created_at
        ))
        total_dur += lnk.duration_sec
    
    creator = db.query(User).filter(User.id == chain.creator_id).first()
    
    print(f"🎙️ [Fun Pack] {current_user.username} added link to chain {chain_id}")
    return ChainResponse(
        id=chain.id,
        group_id=chain.group_id,
        creator_id=chain.creator_id,
        creator_name=creator.username if creator else "Unknown",
        title=chain.title,
        max_duration_sec=chain.max_duration_sec,
        status=chain.status,
        links=links,
        total_duration_sec=total_dur,
        created_at=chain.created_at
    )


@router.get("/{group_id}/voice-chains/{chain_id}", response_model=ChainResponse)
def get_voice_chain(
    group_id: str,
    chain_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get a voice chain with all its links."""
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    
    chain = db.query(VoiceChain).filter(
        VoiceChain.id == chain_id,
        VoiceChain.group_id == group_id
    ).first()
    if not chain:
        raise HTTPException(status_code=404, detail="Voice chain not found")
    
    links = []
    total_dur = 0
    for lnk in chain.links:
        user = db.query(User).filter(User.id == lnk.user_id).first()
        links.append(ChainLinkResponse(
            id=lnk.id,
            user_id=lnk.user_id,
            username=user.username if user else "Unknown",
            audio_url=lnk.audio_url,
            duration_sec=lnk.duration_sec,
            order_index=lnk.order_index,
            created_at=lnk.created_at
        ))
        total_dur += lnk.duration_sec
    
    creator = db.query(User).filter(User.id == chain.creator_id).first()
    
    return ChainResponse(
        id=chain.id,
        group_id=chain.group_id,
        creator_id=chain.creator_id,
        creator_name=creator.username if creator else "Unknown",
        title=chain.title,
        max_duration_sec=chain.max_duration_sec,
        status=chain.status,
        links=links,
        total_duration_sec=total_dur,
        created_at=chain.created_at
    )


@router.post("/{group_id}/voice-chains/{chain_id}/close")
def close_voice_chain(
    group_id: str,
    chain_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Close a voice chain (creator or admin only)."""
    chain = db.query(VoiceChain).filter(
        VoiceChain.id == chain_id,
        VoiceChain.group_id == group_id
    ).first()
    if not chain:
        raise HTTPException(status_code=404, detail="Voice chain not found")
    
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member")
    if chain.creator_id != current_user.id and membership.role != "admin":
        raise HTTPException(status_code=403, detail="Only chain creator or admin can close")
    
    chain.status = "closed"
    db.commit()
    
    print(f"🎙️ [Fun Pack] Voice chain {chain_id} closed by {current_user.username}")
    return {"success": True, "message": "Voice chain closed"}


# ==================== PUBLISH CHAIN AS POST ====================

class PublishChainRequest(BaseModel):
    visibility: str = "public"  # public, friends, local
    caption: Optional[str] = None  # Optional caption text


@router.post("/{group_id}/voice-chains/{chain_id}/publish")
def publish_voice_chain_as_post(
    group_id: str,
    chain_id: str,
    req: PublishChainRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Publish a Voice Chain from group chat as a collaborative post in the feed.
    
    - Only contributors (chain link authors) or group admins can publish.
    - Creates a post with post_type='voice_chain', co_authors, and origin_chain_id.
    - Sends notifications to all co-authors.
    """
    from models import Post, Notification
    from encryption import encrypt_text
    import json as json_mod
    
    # Get chain
    chain = db.query(VoiceChain).filter(
        VoiceChain.id == chain_id,
        VoiceChain.group_id == group_id
    ).first()
    if not chain:
        raise HTTPException(status_code=404, detail="Voice chain not found")
    
    # Get all links (sorted by order)
    links = db.query(VoiceChainLink).filter(
        VoiceChainLink.chain_id == chain_id
    ).order_by(VoiceChainLink.order_index).all()
    
    if not links:
        raise HTTPException(status_code=400, detail="Chain has no recordings yet")
    
    # Check permissions: must be a contributor or admin
    contributor_ids = list(set(link.user_id for link in links))
    
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this group")
    
    is_contributor = current_user.id in contributor_ids
    is_admin = membership.role == "admin"
    is_creator = chain.creator_id == current_user.id
    
    if not (is_contributor or is_admin or is_creator):
        raise HTTPException(status_code=403, detail="Only contributors, chain creator, or admins can publish")
    
    # Validate visibility
    if req.visibility not in ("public", "friends", "local"):
        raise HTTPException(status_code=400, detail="Visibility must be: public, friends, local")
    
    # Build post content
    total_duration = sum(link.duration_sec for link in links)
    
    # Get co-author usernames for display
    co_author_users = db.query(User).filter(User.id.in_(contributor_ids)).all()
    user_map = {u.id: u.username for u in co_author_users}
    co_author_usernames = [user_map.get(uid, "Unknown") for uid in contributor_ids]
    
    # Build caption text
    caption = req.caption or ""
    if not caption:
        names = ", ".join(f"@{name}" for name in co_author_usernames[:3])
        extra = f" +{len(co_author_usernames) - 3}" if len(co_author_usernames) > 3 else ""
        caption = f"🎙️ Voice Chain: {chain.title}\nBy {names}{extra} • {total_duration}s"
    
    # Collect all audio URLs
    media_urls = [link.audio_url for link in links]
    
    # Create the post
    post = Post(
        author_id=current_user.id,
        content=encrypt_text(caption),
        timestamp=datetime.utcnow(),
        is_local=req.visibility == "local",
        visibility=req.visibility,
        post_type="voice_chain",
        voice_url=media_urls[0] if media_urls else None,  # Primary audio
        voice_duration=total_duration,
        origin_chain_id=chain_id,
        co_authors=json_mod.dumps(contributor_ids),
    )
    
    db.add(post)
    db.commit()
    db.refresh(post)
    
    print(f"📢 [Chain Publish] Chain '{chain.title}' published as post {post.id[:8]} by {current_user.username}")
    print(f"   Co-authors: {co_author_usernames}, Visibility: {req.visibility}")
    
    # Fan-out notifications to ALL co-authors (except publisher)
    for co_author_id in contributor_ids:
        if co_author_id == current_user.id:
            continue
        
        notif = Notification(
            user_id=co_author_id,
            type="collab_post_published",
            data=json_mod.dumps({
                "post_id": post.id,
                "chain_id": chain_id,
                "chain_title": chain.title,
                "publisher_id": current_user.id,
                "publisher_username": current_user.username,
                "co_authors": contributor_ids,
                "visibility": req.visibility
            }),
            timestamp=datetime.utcnow(),
            is_read=False
        )
        db.add(notif)
        print(f"🔔 Collab publish notification → {user_map.get(co_author_id, co_author_id[:8])}")
    
    db.commit()
    
    return {
        "success": True,
        "post_id": post.id,
        "post_type": "voice_chain",
        "co_authors": contributor_ids,
        "co_author_usernames": co_author_usernames,
        "visibility": req.visibility,
        "total_duration_sec": total_duration
    }


# ═══════════════════════════════════════════════════════════════════════════
# GROUP VOICE MESSAGE TRANSCRIPTION (Gemini-powered)
# ═══════════════════════════════════════════════════════════════════════════

import os
from fastapi import BackgroundTasks as _GrpBT


async def _run_group_message_transcription(message_id: str, group_id: str):
    """Background task: transcribe a group voice message using Gemini."""
    from database import SessionLocal
    from services.gemini_service import get_gemini_service

    db = SessionLocal()
    try:
        msg = db.query(GroupMessage).filter(
            GroupMessage.id == message_id,
            GroupMessage.group_id == group_id
        ).first()
        if not msg or msg.message_type != "voice" or not msg.audio_url:
            print(f"❌ [GrpMsgTranscribe] Message {message_id[:8]}… not found or not voice")
            return

        msg.transcript_status = "processing"
        db.commit()

        gemini = get_gemini_service()

        # Resolve audio URL
        audio_url = msg.audio_url
        if not audio_url.startswith("http"):
            base = os.environ.get("SERVER_BASE_URL", "").rstrip("/")
            if not base:
                base = "https://raven-server-5iwa2y5n3a-ww.a.run.app"
            audio_url = f"{base}/{audio_url.lstrip('/')}"

        print(f"🎙️ [GrpMsgTranscribe] Resolved audio URL: {audio_url[:100]}...")

        result = await gemini.transcribe_audio(audio_url)

        if result.get("text"):
            msg.transcript_text = result["text"]
            msg.transcript_language = result.get("language")
            msg.transcript_status = "ready"
            db.commit()
            print(f"✅ Group message transcript ready: {message_id[:8]}… lang={result.get('language')}")
        else:
            msg.transcript_status = "failed"
            db.commit()
            print(f"❌ Group message transcript failed: {message_id[:8]}… {result.get('error')}")
    except Exception as e:
        print(f"❌ Group message transcript error: {e}")
        import traceback
        traceback.print_exc()
        try:
            msg = db.query(GroupMessage).filter(GroupMessage.id == message_id).first()
            if msg:
                msg.transcript_status = "failed"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()


@router.post("/{group_id}/messages/{message_id}/transcribe")
async def transcribe_group_voice_message(
    group_id: str,
    message_id: str,
    background_tasks: _GrpBT,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Trigger transcription for a group voice message. Idempotent."""
    # ═══ Premium Rate Limit (3/day for free users, unlimited for premium) ═══
    from middleware.premium_rate_limit import check_ai_quota
    check_ai_quota(current_user)
    # Verify membership
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this group")

    msg = db.query(GroupMessage).filter(
        GroupMessage.id == message_id,
        GroupMessage.group_id == group_id
    ).first()
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")

    if msg.message_type != "voice" or not msg.audio_url:
        raise HTTPException(status_code=400, detail="Not a voice message")

    # Idempotent: return cached if ready
    if msg.transcript_status == "ready":
        return {
            "status": "ready",
            "language": msg.transcript_language,
            "text": msg.transcript_text
        }

    # Already pending/processing
    if msg.transcript_status in ("pending", "processing"):
        return {"status": msg.transcript_status}

    # Queue transcription
    msg.transcript_status = "pending"
    db.commit()

    background_tasks.add_task(_run_group_message_transcription, message_id, group_id)

    print(f"🎙️ Queued group message transcription: {message_id[:8]}… by {current_user.username}")
    return {"status": "pending"}


@router.get("/{group_id}/messages/{message_id}/transcript")
def get_group_message_transcript(
    group_id: str,
    message_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get transcript for a group voice message (poll endpoint)."""
    # Verify membership
    membership = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == current_user.id
    ).first()
    if not membership:
        raise HTTPException(status_code=403, detail="Not a member of this group")

    msg = db.query(GroupMessage).filter(
        GroupMessage.id == message_id,
        GroupMessage.group_id == group_id
    ).first()
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")

    return {
        "status": msg.transcript_status or "none",
        "language": msg.transcript_language,
        "text": msg.transcript_text
    }
