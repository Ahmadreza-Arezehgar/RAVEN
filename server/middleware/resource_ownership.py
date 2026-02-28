"""
Resource Ownership Verification Helper
Prevents IDOR attacks by fetching resource owner from database
"""
from fastapi import HTTPException, status
from sqlalchemy.orm import Session
from typing import Optional
import sys
import os

# Add parent directory to path for imports
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from models import User, Post, Message


def get_and_verify_resource_owner(
    resource_id: str,
    resource_table: str,
    current_user: User,
    db: Session
) -> str:
    """
    Fetch resource owner from DB and verify current user owns it
    
    CRITICAL: Always fetch owner_id from DB, NEVER trust client input
    
    Args:
        resource_id: ID of the resource (post_id, message_id, etc.)
        resource_table: Table name ("posts", "messages")
        current_user: Currently authenticated user
        db: Database session
        
    Returns:
        str: Owner ID if authorized
        
    Raises:
        HTTPException: 404 if resource not found or not authorized
        
    Security:
        - Returns 404 for both "not found" and "not authorized"
        - Prevents enumeration attacks (attacker can't tell if resource exists)
        
    Example:
        # SECURE usage:
        owner_id = get_and_verify_resource_owner(
            message_id, "messages", current_user, db
        )
        
        # VULNERABLE (don't do this):
        user_id = request.query_params.get("user_id")  # ❌ Trusts client!
        check_resource_ownership(user_id, current_user)
    """
    resource = None
    
    # Fetch from database based on table
    if resource_table == "posts":
        from models import Post
        resource = db.query(Post).filter(Post.id == resource_id).first()
        owner_id = resource.user_id if resource else None
    elif resource_table == "messages":
        from models import Message
        resource = db.query(Message).filter(Message.id == resource_id).first()
        owner_id = resource.sender_id if resource else None
    else:
        raise ValueError(f"Unknown resource table: {resource_table}")
    
    # Return 404 for both "not found" and "not authorized"
    # This prevents enumeration attacks
    if not resource or owner_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Resource not found"
        )
    
    return owner_id
