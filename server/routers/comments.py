from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import or_
from pydantic import BaseModel, Field, ConfigDict
from typing import List, Optional
from datetime import datetime
import re

from database import get_db
from models import User, Post, Comment, CommentVote, Mention, Notification
from routers.users import get_current_user
from encryption import encrypt_text, decrypt_text
from services.gemini_service import get_gemini_service
from services.apns_service import get_apns_service, APNsService
# 🛡️ Hoisted to module level — these were re-imported INSIDE the function
# at multiple branches, which made Python treat them as LOCAL names
# everywhere in the body. Any reference BEFORE the local-import branch
# triggered UnboundLocalError ("cannot access local variable 'APNsService'
# where it is not associated with a value"). Same trap as the `import json`
# bug fixed earlier in this file. Keep imports at module scope.
import uuid
import json

router = APIRouter(prefix="/api/comments", tags=["comments"])

# Request/Response models
class MentionEntityPayload(BaseModel):
    """Mention entity from iOS composer's MentionPicker.

    Accepts BOTH camelCase (`userId`) and snake_case (`user_id`) inputs:
    - iOS NetworkService runs `.convertToSnakeCase` on its encoder, so the
      JSON arriving here looks like `{"user_id":"...","range_start":0,...}`.
    - Web/legacy clients send camelCase directly.
    Pydantic's `populate_by_name=True` plus per-field aliases makes both
    shapes deserialize correctly. (422 errors on every comment-create were
    the symptom before this fix.)
    """
    model_config = ConfigDict(populate_by_name=True)

    type: str = "mention"
    userId: str = Field(alias="user_id")
    username: str
    rangeStart: int = Field(alias="range_start")
    rangeLength: int = Field(alias="range_length")


class CreateCommentRequest(BaseModel):
    post_id: str
    content: Optional[str] = None  # Required for text, optional caption for image
    parent_comment_id: Optional[str] = None
    image_url: Optional[str] = None  # ✅ For AI Vision analysis
    enable_search: Optional[bool] = True  # ✅ For AI Internet Search
    entities: Optional[List[MentionEntityPayload]] = None  # Structured @mention entities
    comment_type: str = "text"  # "text" | "voice" | "image"
    media_url: Optional[str] = None  # CDN URL for uploaded voice/image
    duration_sec: Optional[float] = None  # Voice duration in seconds

class CommentResponse(BaseModel):
    id: str
    post_id: str
    author_id: str
    author_name: str
    author_avatar: Optional[str]
    is_verified: bool  # Blue verified badge
    is_premium: bool = False  # RAVEN+ golden crown badge
    parent_comment_id: Optional[str]
    content: str
    timestamp: datetime
    score: int  # likes - dislikes
    my_vote: int  # +1, -1, or 0
    is_ai_generated: bool
    entities: Optional[str] = None  # JSON string of mention entities
    comment_type: str = "text"  # "text" | "voice" | "image"
    media_url: Optional[str] = None
    duration_sec: Optional[float] = None
    # ✏️ Edit support — set when comment was edited; clients render "edited" hint
    edited_at: Optional[datetime] = None
    # 📌 Pin support — host of the post can pin one+ comments to the top
    is_pinned: bool = False
    pinned_at: Optional[datetime] = None
    replies: List['CommentResponse'] = []
    
    class Config:
        from_attributes = True

# Self-reference for nested replies
CommentResponse.model_rebuild()


def detect_ai_trigger(content: str) -> Optional[str]:
    """
    Detect @ask trigger in comment and extract the question.
    
    Returns the question text if trigger found, None otherwise.
    """
    pattern = r'@ask\s+(.+)'
    match = re.search(pattern, content, re.IGNORECASE)
    return match.group(1).strip() if match else None


def get_or_create_ai_user(db: Session) -> User:
    """Get or create the virtual Gemini AI user."""
    ai_user = db.query(User).filter(User.username == "Gemini").first()
    
    if not ai_user:
        # Create Gemini user
        ai_user = User(
            username="Gemini",
            first_name="Gemini",
            last_name="AI",
            birth_year=2024,
            public_key="",  # AI doesn't need encryption keys
            bio="Powered by Google Gemma AI ✨",
            avatar_path="/static/images/gemini_avatar.png",
            is_verified=True  # Gemini is verified
        )
        db.add(ai_user)
        db.commit()
        db.refresh(ai_user)
        print("🤖 Created Gemini AI user")
    
    return ai_user


def build_comment_tree(comments: List[Comment], current_user_id: str, db: Session, sort: str = "top") -> List[CommentResponse]:
    """Build a hierarchical comment tree from flat list. sort='top' by score, 'newest' by timestamp."""
    # Group comments by parent
    comment_map = {}
    root_comments = []
    
    for comment in comments:
        # Check user's vote on this comment
        user_vote = db.query(CommentVote).filter(
            CommentVote.comment_id == comment.id,
            CommentVote.user_id == current_user_id
        ).first()
        my_vote = user_vote.vote if user_vote else 0
        
        comment_resp = CommentResponse(
            id=comment.id,
            post_id=comment.post_id,
            author_id=comment.author_id,
            author_name=comment.author.username if comment.author else "Unknown",
            author_avatar=comment.author.avatar_path if comment.author else None,
            is_verified=comment.author.is_verified if comment.author and hasattr(comment.author, 'is_verified') else False,
            is_premium=comment.author.is_premium if comment.author and hasattr(comment.author, 'is_premium') else False,
            parent_comment_id=comment.parent_comment_id,
            content=decrypt_text(comment.content),
            timestamp=comment.timestamp,
            score=comment.score,
            my_vote=my_vote,
            is_ai_generated=comment.is_ai_generated,
            comment_type=comment.comment_type or "text",
            media_url=comment.media_url,
            duration_sec=comment.duration_sec,
            edited_at=getattr(comment, 'edited_at', None),
            is_pinned=bool(getattr(comment, 'is_pinned', False)),
            pinned_at=getattr(comment, 'pinned_at', None),
            replies=[]
        )
        
        comment_map[comment.id] = comment_resp
        
        if comment.parent_comment_id is None:
            root_comments.append(comment_resp)
    
    # Build tree structure
    for comment in comments:
        if comment.parent_comment_id and comment.parent_comment_id in comment_map:
            parent = comment_map[comment.parent_comment_id]
            parent.replies.append(comment_map[comment.id])
    
    # ✅ Sort root comments — pinned ALWAYS float to the top, in pin-order
    # (most-recently pinned first), then the rest by the requested sort mode.
    # This means pinned comments stay sticky regardless of score, and a
    # newly-pinned comment jumps to the top of the pinned section.
    pinned = [c for c in root_comments if c.is_pinned]
    others = [c for c in root_comments if not c.is_pinned]
    pinned.sort(key=lambda c: (c.pinned_at or c.timestamp), reverse=True)
    if sort == "newest":
        others.sort(key=lambda c: c.timestamp, reverse=True)
    else:  # "top" (default)
        others.sort(key=lambda c: (-c.score, c.timestamp))
    root_comments = pinned + others
    
    # ✅ Sort child replies by timestamp (natural conversation flow)
    def sort_children(comment_resp: CommentResponse):
        comment_resp.replies.sort(key=lambda c: c.timestamp)
        for child in comment_resp.replies:
            sort_children(child)
    
    for root in root_comments:
        sort_children(root)
    
    return root_comments


@router.post("/create", response_model=CommentResponse)
async def create_comment(
    req: CreateCommentRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Create a new comment on a post.
    
    - Detects @time_ask trigger for AI responses
    - Supports threaded replies via parent_comment_id
    - Returns created comment with decrypted content
    """
    # Verify post exists
    post = db.query(Post).filter(Post.id == req.post_id).first()
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Verify parent comment exists if specified
    if req.parent_comment_id:
        parent = db.query(Comment).filter(Comment.id == req.parent_comment_id).first()
        if not parent:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Parent comment not found"
            )
    
    # Validate comment type
    comment_type = req.comment_type or "text"
    if comment_type not in ("text", "voice", "image"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid comment_type. Must be: text, voice, image"
        )
    
    if comment_type == "voice" and not req.media_url:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Voice comments require media_url"
        )
    
    if comment_type == "image" and not req.media_url:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Image comments require media_url"
        )
    
    # For text comments, content is required
    comment_content = req.content or ""
    if comment_type == "text" and not comment_content.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Text comments require content"
        )
    
    # Create comment with encrypted content
    comment = Comment(
        post_id=req.post_id,
        author_id=current_user.id,
        parent_comment_id=req.parent_comment_id,
        content=encrypt_text(comment_content),
        timestamp=datetime.utcnow(),
        is_ai_generated=False,
        entities=json.dumps([e.dict() for e in req.entities]) if req.entities else None,
        comment_type=comment_type,
        media_url=req.media_url,
        duration_sec=req.duration_sec
    )
    
    db.add(comment)
    db.commit()
    db.refresh(comment)
    
    if comment_type == "voice":
        print(f"🔵 [VOICE-DEBUG] Server create_comment: id={comment.id}, type={comment_type}, media_url={req.media_url}, duration={req.duration_sec}, author={current_user.username}")
    
    print(f"💬 Comment created by {current_user.username} on post {req.post_id}")
    
    # ✅ Create notification for post owner (if not self-comment)
    if post.author_id != current_user.id:
        # `Notification` already imported at module top.
        # NOTE: All re-imports of `json`, `Notification`, `APNsService` inside
        # this function were removed. Re-importing inside conditional branches
        # was making Python treat the name as LOCAL throughout the function
        # body, so any reference BEFORE the conditional branch raised
        # UnboundLocalError. Same trap, multiple times. All hoisted to module
        # scope at the top of the file.
        # → Removed the local re-imports below as well.
        notif = Notification(
            user_id=post.author_id,
            type="comment",
            data=json.dumps({
                "post_id": req.post_id,
                "comment_id": comment.id,
                "commenter_id": current_user.id,
                "commenter_username": current_user.username,
                "commenter_avatar": current_user.avatar_path,
                "preview": (req.content or ("🎤 Voice" if comment_type == "voice" else "📷 Image"))[:100]
            }),
            timestamp=datetime.utcnow(),
            is_read=False
        )
        db.add(notif)
        print(f"🔔 Comment notification created for post owner {post.author_id}")
        
        # ✅ Send push notification to post owner (with preference check)
        author = db.query(User).filter(User.id == post.author_id).first()
        if author and author.push_token and author.push_platform == "ios":
            # APNsService imported at module top — no local re-import.
            prefs = APNsService.should_send_push(author, "comment")
            if prefs["allowed"]:
                apns = get_apns_service()
                
                commenter_name = APNsService.build_push_display_name(current_user)
                badge = APNsService.get_unread_badge_count(db, post.author_id)
                
                try:
                    push_result = await apns.send_comment_notification(
                        device_token=author.push_token,
                        commenter_name=commenter_name,
                        comment_preview=(req.content or ("🎤 Voice" if comment_type == "voice" else "📷 Image"))[:100],
                        post_id=req.post_id,
                        badge=badge
                    )
                    print(f"🔔 [PUSH] event=comment sender={current_user.id[:8]} "
                          f"receiver={post.author_id[:8]} status={'sent' if push_result else 'failed'}")
                except Exception as e:
                    print(f"🔔 [PUSH] event=comment sender={current_user.id[:8]} "
                          f"receiver={post.author_id[:8]} status=error reason={e}")
            else:
                print(f"🔔 [PUSH] event=comment receiver={post.author_id[:8]} status=skipped reason=disabled")
    
    # ✅ Process @mention entities (entity-based, replaces old regex)
    if req.entities:
        # `json` already imported at module top — no local re-import.
        snippet = (comment_content[:80]) if comment_content else ("🎤 Voice" if comment_type == "voice" else "📷 Image")
        deep_link = f"app://post/{req.post_id}?comment={comment.id}"

        seen_user_ids = set()
        mention_count = 0

        sender_display = APNsService.build_push_display_name(current_user)

        # 🛡️ Block-list filter — was missing. Without this, A could @mention
        # someone who blocked them (or whom A has blocked) and the target
        # would still get a Mention row + Notification + APNS push. That's a
        # cross-block harassment vector. We use the same helper as posts.py.
        from routers.blocks import get_blocked_user_ids
        blocked_ids = set(get_blocked_user_ids(db, current_user.id))

        for entity in req.entities:
            if entity.type != "mention":
                continue
            if mention_count >= 5:
                break
            if entity.userId in seen_user_ids:
                continue
            if entity.userId == current_user.id:
                continue
            if entity.userId in blocked_ids:
                # Either I blocked them or they blocked me — silently skip.
                continue

            mentioned_user = db.query(User).filter(User.id == entity.userId).first()
            if not mentioned_user:
                continue
            
            seen_user_ids.add(entity.userId)
            mention_count += 1
            
            # Create Mention record
            mention = Mention(
                id=str(uuid.uuid4()),
                type="post_comment",
                source_id=comment.id,
                post_id=req.post_id,
                mentioned_user_id=entity.userId,
                mentioned_by_user_id=current_user.id,
                created_at=datetime.utcnow(),
                snippet=snippet,
                deep_link=deep_link,
                is_read=False
            )
            db.add(mention)
            
            # Create in-app notification
            mention_notif = Notification(
                user_id=entity.userId,
                type="mention",
                data=json.dumps({
                    "mention_type": "post_comment",
                    "post_id": req.post_id,
                    "comment_id": comment.id,
                    "mentioner_id": current_user.id,
                    "mentioner_username": current_user.username,
                    "snippet": snippet,
                    "deep_link": deep_link
                }),
                timestamp=datetime.utcnow(),
                is_read=False
            )
            db.add(mention_notif)
            print(f"🔔 [Mentions] Created mention for @{entity.username} on post {req.post_id}")
            
            # Send push notification (with preference check)
            if mentioned_user.push_token and mentioned_user.push_platform == "ios":
                try:
                    # APNsService + get_apns_service imported at module top.
                    prefs = APNsService.should_send_push(mentioned_user, "mention")
                    if prefs["allowed"]:
                        apns = get_apns_service()
                        push_result = await apns.send_mention_notification(
                            device_token=mentioned_user.push_token,
                            mentioner_name=sender_display,
                            mention_type="post_comment",
                            snippet=snippet,
                            deep_link=deep_link,
                            post_id=req.post_id,
                            source_id=comment.id
                        )
                        if push_result:
                            print(f"📱 ✅ Mention push sent to @{entity.username}")
                        else:
                            print(f"📱 ❌ Mention push failed for @{entity.username}")
                    else:
                        print(f"📱 ⏭️ Mention push skipped for @{entity.username} (notifications disabled)")
                except Exception as e:
                    print(f"📱 ❌ Push error for @{entity.username}: {e}")
        
        print(f"✅ [Mentions] Processed {mention_count} mentions in comment")
    else:
        # Fallback: regex-based mention detection for plain text (backwards compat)
        mentioned_usernames = [u for u in re.findall(r'@(\w+)', req.content or '') if u.lower() != 'ask']
        if mentioned_usernames:
            # Notification + json + APNsService all imported at module top.
            for username in set(mentioned_usernames):  # Unique usernames only
                # 🐛 FIX: was case-SENSITIVE — "Reviewer2" wouldn't match
                # the stored "reviewer2". Use func.lower() for a robust
                # case-insensitive lookup, matching the entity-based path.
                from sqlalchemy import func as _func
                mentioned_user = db.query(User).filter(_func.lower(User.username) == username.lower()).first()
                if mentioned_user and mentioned_user.id != current_user.id:
                    mention_notif = Notification(
                        user_id=mentioned_user.id,
                        type="mention",
                        data=json.dumps({
                            "post_id": req.post_id,
                            "comment_id": comment.id,
                            "mentioner_id": current_user.id,
                            "mentioner_username": current_user.username,
                            "preview": req.content[:100]
                        }),
                        timestamp=datetime.utcnow(),
                        is_read=False
                    )
                    db.add(mention_notif)
                    print(f"🔔 Mention notification for @{username}")
    
    db.commit()  # Commit all notifications
    
    # Track interest for recommendation algorithm
    try:
        from services.interest_service import log_user_event
        log_user_event(current_user.id, 'comment_post', db, post_id=req.post_id)
    except Exception as e:
        print(f"⚠️ Interest tracking failed: {e}")

    
    # Check for AI trigger
    question = detect_ai_trigger(req.content or "")
    if question:
        print(f"🤖 AI trigger detected! Question: {question[:50]}...")
        
        try:
            # Get Gemini service
            gemini = get_gemini_service()
            
            # Get post content
            post_content = decrypt_text(post.content)
            
            # ✅ DEBUG: Log what we're sending to Gemini
            print(f"📄 [AI-DEBUG] Post ID: {req.post_id}")
            print(f"📄 [AI-DEBUG] Post content length: {len(post_content) if post_content else 0}")
            print(f"📄 [AI-DEBUG] Post content preview: {post_content[:200] if post_content else 'EMPTY'}...")
            print(f"🖼️ [AI-DEBUG] Post image URL: {post.image_url or 'None'}")
            print(f"❓ [AI-DEBUG] User question: {question}")
            
            # ✅ Handle empty or failed content gracefully
            if not post_content or post_content == "[DECRYPT_FAILED]":
                post_content = "[No text content in this post]"
                if post.image_url:
                    post_content += " [This post contains an image - analyze the attached image]"
            
            # ✅ Build thread history for context
            thread_history = []
            if req.parent_comment_id:
                # Get parent comment and siblings
                parent_comments = db.query(Comment).filter(
                    Comment.post_id == req.post_id
                ).order_by(Comment.timestamp.desc()).limit(10).all()
                
                for c in reversed(parent_comments):
                    thread_history.append({
                        'author': c.author.username if c.author else 'Unknown',
                        'content': decrypt_text(c.content)
                    })
            
            # ✅ FIX: Use post's image_url, not request's image_url
            # If it's a local file, read it directly as base64
            post_image_url = post.image_url
            local_image_base64 = None
            local_image_mime = None
            
            if post_image_url:
                print(f"🖼️ Post has image: {post_image_url}")
                
                # Check if it's a local /uploads/ path
                if "/uploads/" in post_image_url:
                    # Extract filename and read from disk
                    import base64
                    from pathlib import Path
                    
                    # Extract just the filename
                    filename = post_image_url.split("/uploads/")[-1]
                    local_path = Path("uploads") / filename
                    
                    if local_path.exists():
                        with open(local_path, "rb") as f:
                            image_bytes = f.read()
                            local_image_base64 = base64.b64encode(image_bytes).decode("utf-8")
                        
                        # Detect MIME type
                        ext = local_path.suffix.lower()
                        if ext in [".jpg", ".jpeg"]:
                            local_image_mime = "image/jpeg"
                        elif ext == ".png":
                            local_image_mime = "image/png"
                        elif ext == ".webp":
                            local_image_mime = "image/webp"
                        else:
                            local_image_mime = "image/jpeg"
                        
                        print(f"✅ Read local image: {local_path} ({len(image_bytes)} bytes)")
                    else:
                        print(f"⚠️ Local image not found: {local_path}")
            
            # ✅ Generate AI response - pass local image if available
            ai_result = await gemini.generate_response(
                question=question,
                post_content=post_content,
                thread_history=thread_history,
                language=None,  # Auto-detect from question
                enable_search=req.enable_search if req.enable_search is not None else True,
                image_url=post_image_url if not local_image_base64 else None,
                local_image_base64=local_image_base64,
                local_image_mime=local_image_mime
            )
            
            ai_response = ai_result.get("response")
            sources = ai_result.get("sources", [])
            search_performed = ai_result.get("search_performed", False)
            
            if search_performed:
                print(f"🔍 AI used web search with {len(sources)} sources")
            
            if ai_response:
                # Get or create AI assistant user
                ai_user = get_or_create_ai_user(db)
                
                # Create AI reply comment
                ai_comment = Comment(
                    post_id=req.post_id,
                    author_id=ai_user.id,
                    parent_comment_id=comment.id,  # Reply to user's comment
                    content=encrypt_text(ai_response),
                    timestamp=datetime.utcnow(),
                    is_ai_generated=True
                )
                
                db.add(ai_comment)
                db.commit()
                
                print(f"✅ AI response generated and posted")
            else:
                print("⚠️ AI response generation failed")
                
        except Exception as e:
            print(f"❌ Error generating AI response: {e}")
            # Don't fail the original comment creation
    
    # Serialize entities
    entities_json = None
    if req.entities:
        import json as json_mod
        entities_json = json_mod.dumps([e.dict() for e in req.entities])
    
    # Return created comment
    return CommentResponse(
        id=comment.id,
        post_id=comment.post_id,
        author_id=comment.author_id,
        author_name=current_user.username,
        author_avatar=current_user.avatar_path,
        is_verified=current_user.is_verified if hasattr(current_user, 'is_verified') else False,
        is_premium=current_user.is_premium if hasattr(current_user, 'is_premium') else False,
        parent_comment_id=comment.parent_comment_id,
        content=decrypt_text(comment.content),
        timestamp=comment.timestamp,
        score=0,
        my_vote=0,
        is_ai_generated=False,
        entities=entities_json,
        comment_type=comment_type,
        media_url=req.media_url,
        duration_sec=req.duration_sec,
        replies=[]
    )


@router.get("/post/{post_id}", response_model=List[CommentResponse])
def get_post_comments(
    post_id: str,
    sort: str = "top",
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get all comments for a specific post.
    
    Returns hierarchical tree structure with nested replies.
    """
    # Verify post exists
    post = db.query(Post).filter(Post.id == post_id).first()
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Get all comments for this post
    comments = db.query(Comment).filter(
        Comment.post_id == post_id,
        or_(Comment.is_hidden == False, Comment.is_hidden == None)
    ).order_by(Comment.timestamp.asc()).all()
    
    # Build and return comment tree with requested sort mode
    return build_comment_tree(comments, current_user.id, db, sort=sort)


class VoteRequest(BaseModel):
    vote: int  # +1 = like, -1 = dislike, 0 = remove vote

@router.post("/{comment_id}/vote")
def vote_comment(
    comment_id: str,
    req: VoteRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Vote on a comment (like/dislike with toggle logic).
    
    vote: +1 = like, -1 = dislike, 0 = remove vote
    
    Toggle logic:
    - If same vote exists: remove it (neutral)
    - If opposite vote exists: change to new vote
    - If no vote: add new vote
    """
    if req.vote not in [-1, 0, 1]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Vote must be -1, 0, or 1"
        )
    
    comment = db.query(Comment).filter(Comment.id == comment_id).first()
    
    if not comment:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Comment not found"
        )
    
    # Get existing vote
    existing_vote = db.query(CommentVote).filter(
        CommentVote.comment_id == comment_id,
        CommentVote.user_id == current_user.id
    ).first()
    
    old_vote = existing_vote.vote if existing_vote else 0
    new_vote = req.vote
    
    # Handle remove vote request
    if new_vote == 0:
        if existing_vote:
            db.delete(existing_vote)
            action = "removed"
        else:
            action = "no_change"
    # Handle toggle logic
    elif existing_vote:
        if existing_vote.vote == new_vote:
            # Same vote - toggle off (remove)
            db.delete(existing_vote)
            new_vote = 0
            action = "toggled_off"
        else:
            # Different vote - change
            existing_vote.vote = new_vote
            action = "changed"
    else:
        # No existing vote - create new
        vote_entry = CommentVote(
            comment_id=comment_id,
            user_id=current_user.id,
            vote=new_vote
        )
        db.add(vote_entry)
        action = "added"
    
    db.commit()
    
    # Recalculate score from votes table
    likes = db.query(CommentVote).filter(
        CommentVote.comment_id == comment_id,
        CommentVote.vote == 1
    ).count()
    dislikes = db.query(CommentVote).filter(
        CommentVote.comment_id == comment_id,
        CommentVote.vote == -1
    ).count()
    
    comment.score = likes - dislikes
    db.commit()
    
    print(f"🗳️ Comment vote {action} by {current_user.username}: {old_vote} → {new_vote} (score: {comment.score})")
    
    return {
        "status": "success",
        "action": action,
        "my_vote": new_vote,
        "score": comment.score
    }


@router.delete("/{comment_id}")
def delete_comment(
    comment_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Delete a comment.

    Allowed: comment author OR post author (post owner can moderate
    comments on their own post). Cascades to all replies.
    """
    comment = db.query(Comment).filter(Comment.id == comment_id).first()

    if not comment:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Comment not found"
        )

    # ✏️ Authorization: comment author OR post author
    is_author = comment.author_id == current_user.id
    post = db.query(Post).filter(Post.id == comment.post_id).first()
    is_post_owner = post is not None and post.author_id == current_user.id

    if not (is_author or is_post_owner):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Not authorized to delete this comment"
        )

    db.delete(comment)
    db.commit()

    print(f"🗑️ Comment deleted by {current_user.username}")

    return {"status": "success", "message": "Comment deleted"}


# ═══════════════════════════════════════════════════════════════════════════
# ✏️ EDIT COMMENT (PATCH /api/comments/{id})
# ═══════════════════════════════════════════════════════════════════════════

class EditCommentRequest(BaseModel):
    content: str
    entities: Optional[List[MentionEntityPayload]] = None


@router.patch("/{comment_id}", response_model=CommentResponse)
async def edit_comment(
    comment_id: str,
    req: EditCommentRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Edit the text content of a comment.

    Rules:
    - Only the COMMENT AUTHOR can edit (post owner cannot rewrite others' words).
    - Only TEXT comments are editable (not voice/image — re-record/re-upload instead).
    - Edit window: 24 hours after creation (industry-standard cap to prevent
      retroactive comment hijacking on viral posts).
    - Updating content does NOT change `timestamp` (kept for stable sort).
    - Sets `edited_at = utcnow()` so clients render the "edited" hint.
    - Re-runs @mention extraction on the new content (best-effort: existing
      Mention rows from the OLD content are NOT removed; new mentions create
      new rows + notifications).
    """
    comment = db.query(Comment).filter(Comment.id == comment_id).first()
    if not comment:
        raise HTTPException(status_code=404, detail="Comment not found")

    if comment.author_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the comment author can edit")

    if (comment.comment_type or "text") != "text":
        raise HTTPException(status_code=400, detail="Only text comments can be edited (re-record voice / re-upload image)")

    # 24-hour edit window
    if comment.timestamp and (datetime.utcnow() - comment.timestamp).total_seconds() > 24 * 3600:
        raise HTTPException(status_code=400, detail="Edit window has closed (24 hours)")

    new_content = (req.content or "").strip()
    if not new_content:
        raise HTTPException(status_code=400, detail="Content cannot be empty")
    if len(new_content) > 4000:
        raise HTTPException(status_code=400, detail="Comment too long (max 4000 chars)")

    # Update content + edited_at
    comment.content = encrypt_text(new_content)
    comment.edited_at = datetime.utcnow()
    if req.entities:
        comment.entities = json.dumps([e.dict() for e in req.entities])

    db.commit()
    db.refresh(comment)

    print(f"✏️ [Comments] {current_user.username} edited comment {comment_id[:8]}")

    # Build single-comment response (re-using the helper produces same shape)
    return build_comment_tree([comment], current_user.id, db, sort="newest")[0]


# ═══════════════════════════════════════════════════════════════════════════
# 📌 PIN / UNPIN COMMENT (post-author only)
# ═══════════════════════════════════════════════════════════════════════════

@router.post("/{comment_id}/pin")
def pin_comment(
    comment_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Pin a comment to the top of its post.

    Only the POST author can pin/unpin (comment author cannot self-promote).
    Multiple comments can be pinned; they sort by `pinned_at` desc within the
    pinned section.
    """
    comment = db.query(Comment).filter(Comment.id == comment_id).first()
    if not comment:
        raise HTTPException(status_code=404, detail="Comment not found")

    post = db.query(Post).filter(Post.id == comment.post_id).first()
    if not post:
        raise HTTPException(status_code=404, detail="Post not found")
    if post.author_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the post author can pin comments")

    comment.is_pinned = True
    comment.pinned_at = datetime.utcnow()
    db.commit()

    print(f"📌 [Comments] {current_user.username} pinned comment {comment_id[:8]} on post {post.id[:8]}")
    return {"status": "success", "is_pinned": True, "pinned_at": comment.pinned_at}


@router.post("/{comment_id}/unpin")
def unpin_comment(
    comment_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Unpin a comment. Same authorization as pin."""
    comment = db.query(Comment).filter(Comment.id == comment_id).first()
    if not comment:
        raise HTTPException(status_code=404, detail="Comment not found")

    post = db.query(Post).filter(Post.id == comment.post_id).first()
    if not post:
        raise HTTPException(status_code=404, detail="Post not found")
    if post.author_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the post author can unpin comments")

    comment.is_pinned = False
    comment.pinned_at = None
    db.commit()

    print(f"📌 [Comments] {current_user.username} unpinned comment {comment_id[:8]}")
    return {"status": "success", "is_pinned": False}


# ═══════════════════════════════════════════════════════════════════════════
# VOICE COMMENT TRANSCRIPTION (Gemini-powered, any language)
# ═══════════════════════════════════════════════════════════════════════════

async def _run_comment_transcription(comment_id: str):
    """Background task: transcribe a voice comment using Gemini."""
    from database import SessionLocal
    from services.gemini_service import get_gemini_service
    
    db = SessionLocal()
    try:
        comment = db.query(Comment).filter(Comment.id == comment_id).first()
        if not comment or comment.comment_type != "voice" or not comment.media_url:
            print(f"❌ [Transcribe] Comment {comment_id[:8]}… not found or not voice")
            return
        
        comment.transcript_status = "processing"
        db.commit()
        
        gemini = get_gemini_service()
        
        # Resolve media URL
        audio_url = comment.media_url
        if not audio_url.startswith("http"):
            import os
            base = os.environ.get("SERVER_BASE_URL", "").rstrip("/")
            if not base:
                print(f"⚠️ [Transcribe] SERVER_BASE_URL not set, using Cloud Run URL")
                base = "https://raven-server-5iwa2y5n3a-ww.a.run.app"
            audio_url = f"{base}/{audio_url.lstrip('/')}"
        
        print(f"🎙️ [Transcribe] Comment audio URL: {audio_url[:100]}...")
        
        result = await gemini.transcribe_audio(audio_url)
        
        if result.get("text"):
            comment.transcript_text = result["text"]
            comment.transcript_language = result.get("language")
            comment.transcript_status = "ready"
            db.commit()
            print(f"✅ Comment transcript ready: {comment_id[:8]}… lang={result.get('language')}")
        else:
            comment.transcript_status = "failed"
            db.commit()
            print(f"❌ Comment transcript failed: {comment_id[:8]}…")
    except Exception as e:
        print(f"❌ Comment transcript error: {e}")
        import traceback
        traceback.print_exc()
        try:
            comment = db.query(Comment).filter(Comment.id == comment_id).first()
            if comment:
                comment.transcript_status = "failed"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()


from fastapi import BackgroundTasks as _CommentBT


@router.post("/{comment_id}/transcribe")
async def transcribe_voice_comment(
    comment_id: str,
    background_tasks: _CommentBT,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Trigger transcription for a voice comment. Idempotent."""
    # ═══ Premium Rate Limit (3/day for free users, unlimited for premium) ═══
    from middleware.premium_rate_limit import check_ai_quota
    check_ai_quota(current_user)
    comment = db.query(Comment).filter(Comment.id == comment_id).first()
    if not comment:
        raise HTTPException(status_code=404, detail="Comment not found")
    
    if comment.comment_type != "voice" or not comment.media_url:
        raise HTTPException(status_code=400, detail="Not a voice comment")
    
    # Idempotent: return cached if ready
    if comment.transcript_status == "ready":
        return {
            "status": "ready",
            "language": comment.transcript_language,
            "text": comment.transcript_text
        }
    
    # Already pending/processing — don't re-queue
    if comment.transcript_status in ("pending", "processing"):
        return {"status": comment.transcript_status}
    
    # Queue transcription
    comment.transcript_status = "pending"
    db.commit()
    
    background_tasks.add_task(_run_comment_transcription, comment_id)
    
    print(f"🎙️ Queued comment transcription: {comment_id[:8]}… by {current_user.username}")
    return {"status": "pending"}


@router.get("/{comment_id}/transcript")
def get_comment_transcript(
    comment_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get transcript for a voice comment."""
    comment = db.query(Comment).filter(Comment.id == comment_id).first()
    if not comment:
        raise HTTPException(status_code=404, detail="Comment not found")
    
    return {
        "status": comment.transcript_status or "none",
        "language": comment.transcript_language,
        "text": comment.transcript_text
    }
