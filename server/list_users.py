from database_config import SessionLocal
from models import User

db = SessionLocal()
users = db.query(User).all()
for u in users:
    print(f"User: {u.id} - {u.username} - {u.display_name}")
db.close()
