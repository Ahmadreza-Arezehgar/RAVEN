"""
Migration script to fix/create view counting infrastructure.

Run this script ONCE to setup proper unique view tracking:
  python fix_duplicate_views.py
"""

import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).parent / "encrypted.db"

def fix_views():
    print(f"🔧 Fixing view counting in {DB_PATH}")
    
    if not DB_PATH.exists():
        print("❌ Database not found!")
        return
    
    conn = sqlite3.connect(str(DB_PATH))
    cursor = conn.cursor()
    
    try:
        # Step 1: Check/add view_count column to posts table
        cursor.execute("PRAGMA table_info(posts)")
        columns = [col[1] for col in cursor.fetchall()]
        
        if 'view_count' not in columns:
            print("📋 posts.view_count column does NOT exist!")
            print("   Adding column...")
            cursor.execute("ALTER TABLE posts ADD COLUMN view_count INTEGER DEFAULT 0")
            print("✅ view_count column added!")
        else:
            print("✅ posts.view_count column exists")
        
        # Step 2: Check/create post_views table
        cursor.execute("""
            SELECT name FROM sqlite_master 
            WHERE type='table' AND name='post_views'
        """)
        table_exists = cursor.fetchone() is not None
        
        if not table_exists:
            print("📋 post_views table does NOT exist!")
            print("   Creating table with unique constraint...")
            cursor.execute("""
                CREATE TABLE post_views (
                    id TEXT PRIMARY KEY,
                    post_id TEXT NOT NULL,
                    viewer_key TEXT NOT NULL,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                    UNIQUE(post_id, viewer_key)
                )
            """)
            cursor.execute("CREATE INDEX idx_post_views_post_id ON post_views(post_id)")
            cursor.execute("CREATE INDEX idx_post_views_viewer ON post_views(viewer_key)")
            print("✅ post_views table created!")
            
            # Reset view_counts since they were never tracked properly
            print("🔧 Resetting all view_count to 0...")
            cursor.execute("UPDATE posts SET view_count = 0")
            cursor.execute("SELECT COUNT(*) FROM posts")
            count = cursor.fetchone()[0]
            print(f"✅ Reset {count} posts")
        else:
            print("✅ post_views table exists")
            
            # Check for duplicates
            cursor.execute("""
                SELECT COUNT(*) FROM (
                    SELECT post_id, viewer_key 
                    FROM post_views 
                    GROUP BY post_id, viewer_key 
                    HAVING COUNT(*) > 1
                )
            """)
            dup_count = cursor.fetchone()[0]
            
            if dup_count > 0:
                print(f"🔍 Found {dup_count} duplicate views, cleaning up...")
                # Dedupe by recreating table
                cursor.execute("DROP TABLE IF EXISTS post_views_clean")
                cursor.execute("""
                    CREATE TABLE post_views_clean (
                        id TEXT PRIMARY KEY,
                        post_id TEXT NOT NULL,
                        viewer_key TEXT NOT NULL,
                        created_at DATETIME NOT NULL,
                        UNIQUE(post_id, viewer_key)
                    )
                """)
                cursor.execute("""
                    INSERT OR IGNORE INTO post_views_clean 
                    SELECT * FROM post_views GROUP BY post_id, viewer_key
                """)
                cursor.execute("DROP TABLE post_views")
                cursor.execute("ALTER TABLE post_views_clean RENAME TO post_views")
                cursor.execute("CREATE INDEX idx_post_views_post_id ON post_views(post_id)")
                cursor.execute("CREATE INDEX idx_post_views_viewer ON post_views(viewer_key)")
                print("✅ Duplicates removed!")
            else:
                print("✅ No duplicates found!")
            
            # Sync counts
            print("🔧 Syncing view_count with actual views...")
            cursor.execute("""
                UPDATE posts 
                SET view_count = (
                    SELECT COUNT(*) FROM post_views WHERE post_views.post_id = posts.id
                )
            """)
            print("✅ Counts synced!")
        
        conn.commit()
        print("\n✅ DONE! View tracking infrastructure is ready.")
        print("   Restart the server to enable proper view counting.")
        
    except Exception as e:
        print(f"❌ Error: {e}")
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    fix_views()
