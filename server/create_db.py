#!/usr/bin/env python3
"""Create database tables with OAuth support."""
import sys
sys.path.insert(0, '/Users/ahmd/hybrid_messenger/server')

from database import Base, engine
from models import User, Message, Post, FriendRequest, ScreenshotNotification, Comment, CommentLike

# Create all tables
print("Creating database tables...")
Base.metadata.create_all(bind=engine)
print("✅ Database tables created successfully!")

# Verify users table has OAuth columns
from sqlalchemy import inspect
inspector = inspect(engine)
columns = inspector.get_columns('users')
column_names = [col['name'] for col in columns]
print(f"\nUsers table columns: {column_names}")

if 'oauth_provider' in column_names and 'oauth_provider_id' in column_names:
    print("✅ OAuth columns exist!")
else:
    print("❌ OAuth columns missing!")
