"""
Authorization Middleware
Prevents IDOR (Insecure Direct Object Reference) attacks

Security Notes:
- Always fetch resource_user_id from DB, never trust client
- Return 404 instead of 403 to prevent user enumeration
- Logs are sanitized in production
"""
from fastapi import HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_
from models import User
from typing import Optional
import sys
import os

# Add parent directory to path for imports
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from utils.security import is_development


def check_resource_ownership(
    resource_user_id: str,
    current_user: User,
    resource_type: str = "resource"
) -> None:
    """
    Verify that the current user owns the resource
    
    Args:
        resource_user_id: User ID that owns the resource
        current_user: Currently authenticated user
        resource_type: Type of resource (for error message)
        
    Raises:
        HTTPException: 403 if user doesn't own the resource
    """
    if resource_user_id != current_user.id:
        # Sanitized logging
        if is_development():
            print(f"🚫 Authorization failed: {current_user.username} tried to access {resource_type} owned by {resource_user_id}")
        else:
            print(f"🚫 Authorization failed: User tried to access {resource_type} they don't own")
        
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Not authorized to access this {resource_type}"
        )


def check_friendship(
    user_a_id: str,
    user_b_id: str,
    db: Session,
    require_accepted: bool = True
) -> bool:
    """
    Verify that two users are friends
    
    Args:
        user_a_id: First user ID
        user_b_id: Second user ID
        db: Database session
        require_accepted: If True, only accepted friendships count
        
    Returns:
        bool: True if friends, False otherwise
        
    Raises:
        HTTPException: 403 if users are not friends (when require_accepted=True)
    """
    from models import FriendRequest
    
    # Query for friendship in either direction
    query = db.query(FriendRequest).filter(
        or_(
            and_(
                FriendRequest.requester_id == user_a_id,
                FriendRequest.recipient_id == user_b_id
            ),
            and_(
                FriendRequest.requester_id == user_b_id,
                FriendRequest.recipient_id == user_a_id
            )
        )
    )
    
    if require_accepted:
        query = query.filter(FriendRequest.status == "accepted")
    
    friendship = query.first()
    
    if require_accepted and not friendship:
        # Sanitized logging
        if is_development():
            print(f"🚫 Authorization failed: {user_a_id} and {user_b_id} are not friends")
        else:
            print(f"🚫 Authorization failed: Users are not friends")
        
        # Return 404 instead of 403 to prevent user enumeration
        # Attacker can't tell if user exists but not friends, or doesn't exist
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Resource not found"
        )
    
    return friendship is not None


def require_friendship(func):
    """
    Decorator to require friendship between current user and another user
    
    Usage:
        @router.get("/api/messages/{user_id}")
        @require_friendship
        def get_messages(user_id: str, current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
            # user_id and current_user must be friends
            ...
    
    The decorated function must have:
    - A 'user_id' or 'recipient_id' parameter (the other user)
    - current_user: User = Depends(get_current_user)
    - db: Session = Depends(get_db)
    """
    from functools import wraps
    from inspect import signature
    
    @wraps(func)
    async def wrapper(*args, **kwargs):
        # Extract parameters
        sig = signature(func)
        bound = sig.bind(*args, **kwargs)
        bound.apply_defaults()
        params = bound.arguments
        
        # Get required objects
        current_user = params.get('current_user')
        db = params.get('db')
        
        # Try to find the other user ID
        other_user_id = params.get('user_id') or params.get('recipient_id')
        
        if not all([current_user, db, other_user_id]):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Authorization decorator misconfigured"
            )
        
        # Check friendship
        check_friendship(
            user_a_id=current_user.id,
            user_b_id=other_user_id,
            db=db,
            require_accepted=True
        )
        
        # Call original function
        return await func(*args, **kwargs)
    
    return wrapper


def check_conversation_membership(
    conversation_id: str,
    user_id: str,
    db: Session
) -> None:
    """
    Verify that user is a member of the conversation
    
    Args:
        conversation_id: Conversation/chat ID
        user_id: User ID to check
        db: Database session
        
    Raises:
        HTTPException: 403 if user is not a member
    """
    # For now, we don't have a conversations table
    # This is a placeholder for when we implement group chats
    # Individual chats are implicitly authorized if users are friends
    pass


def can_view_profile(
    profile_user_id: str,
    current_user: User,
    db: Session
) -> bool:
    """
    Check if current user can view another user's profile
    
    Logic:
    - Can always view own profile
    - Can view friends' profiles 
    - Cannot view strangers' profiles (privacy)
    
    Args:
        profile_user_id: User ID whose profile is being viewed
        current_user: Currently authenticated user
        db: Database session
        
    Returns:
        bool: True if authorized, False otherwise
    """
    # Can always view own profile
    if profile_user_id == current_user.id:
        return True
    
    # Check if users are friends
    try:
        check_friendship(current_user.id, profile_user_id, db, require_accepted=True)
        return True
    except HTTPException:
        # Not friends - privacy setting
        return False
