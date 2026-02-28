import os
from sqlalchemy import create_engine, text, event
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker

# Determine environment
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")

if ENVIRONMENT == "production":
    # PostgreSQL for production (Cloud SQL)
    # Build DATABASE_URL from individual environment variables
    DB_USER = os.getenv("DB_USER", "messenger-user")
    DB_PASSWORD = os.getenv("DB_PASSWORD")
    DB_NAME = os.getenv("DB_NAME", "messenger")
    CLOUD_SQL_CONNECTION = os.getenv("CLOUD_SQL_CONNECTION")
    
    if not DB_PASSWORD:
        raise ValueError("DB_PASSWORD must be set in production")
    
    if CLOUD_SQL_CONNECTION:
        # Cloud SQL via Unix socket
        SQLALCHEMY_DATABASE_URL = f"postgresql://{DB_USER}:{DB_PASSWORD}@/{DB_NAME}?host=/cloudsql/{CLOUD_SQL_CONNECTION}"
    else:
        # Direct connection (for local testing with production DB)
        DB_HOST = os.getenv("DB_HOST", "localhost")
        SQLALCHEMY_DATABASE_URL = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}/{DB_NAME}"
    
    print(f"🔗 [Database] Connecting to PostgreSQL (production)")
    
    engine = create_engine(
        SQLALCHEMY_DATABASE_URL,
        pool_size=20,          # Base connections kept alive
        max_overflow=30,       # Extra connections under load (total max = 50 per instance)
        pool_timeout=30,       # Wait up to 30s for a connection before error
        pool_recycle=300,      # Recycle connections after 5min (frees idle connections faster)
        pool_pre_ping=True,    # Verify connections before use (detects dropped connections)
        echo=False
    )
    
    # Log pool configuration at startup
    print(f"📊 [Database] Pool config: pool_size=20, max_overflow=30, "
          f"pool_timeout=30, pool_recycle=300, pool_pre_ping=True")
    
    # Try to verify PostgreSQL connectivity (with retries), but don't crash
    # if temporarily unreachable (e.g., during Cloud SQL restart or pool exhaustion)
    import time as _time
    _db_verified = False
    for _attempt in range(3):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            print("✅ [Database] PostgreSQL connection verified")
            _db_verified = True
            break
        except Exception as e:
            print(f"⚠️ [Database] Connection attempt {_attempt + 1}/3 failed: {e}")
            if _attempt < 2:
                _time.sleep(5)
    if not _db_verified:
        print("⚠️ [Database] Could not verify PostgreSQL - will retry on first request")
else:
    # SQLite for development
    SQLALCHEMY_DATABASE_URL = "sqlite:///./encrypted.db"
    
    print(f"🔗 [Database] Using SQLite (development)")
    
    engine = create_engine(
        SQLALCHEMY_DATABASE_URL,
        connect_args={
            "check_same_thread": False,
            "timeout": 30
        }
    )

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

def get_db():
    """Dependency for getting database session.
    
    Properly manages session lifecycle:
    - Commits on success
    - Rollbacks on exception (prevents 'idle in transaction' leaks)
    - Always closes the connection (returns it to pool)
    """
    db = SessionLocal()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
