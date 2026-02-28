"""
Database migration script for screenshot notifications.

Run this script to create the screenshot_notifications table in your database.
"""

from database import engine, Base
from models import User, Message, Post, FriendRequest, ScreenshotNotification

def migrate():
    """Create or update database tables."""
    print("🔧 Running database migration...")
    print("📋 Creating tables: users, messages, posts, friend_requests, screenshot_notifications")
    
    # Create all tables (will only create missing ones)
    Base.metadata.create_all(bind=engine)
    
    print("✅ Database migration completed successfully!")
    print("\n📊 Tables in database:")
    print("  - users")
    print("  - messages")
    print("  - posts")
    print("  - friend_requests")
    print("  - screenshot_notifications  (NEW)")

if __name__ == "__main__":
    migrate()
