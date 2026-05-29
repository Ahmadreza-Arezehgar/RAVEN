import uuid
from datetime import datetime, timezone, timedelta
from database_config import SessionLocal
from models import User, Post, Comment, Message

db = SessionLocal()

user_main = db.query(User).filter(User.username == "A_Arezehgar").first()
user_peer = db.query(User).filter(User.username == "Main_Z3ous").first()
user_sarah = db.query(User).filter(User.username == "Sarah_M").first()

if not user_main or not user_peer:
    print("Users A_Arezehgar or Main_Z3ous not found!")
    exit(1)

print("Creating posts for App Store screenshots...")
post1 = Post(
    id=str(uuid.uuid4()),
    author_id=user_main.id,
    content="Just testing the new RAVEN features. The mesh network works flawlessly! 🐦‍⬛",
    timestamp=datetime.utcnow() - timedelta(hours=2),
    visibility="public",
    post_type="text",
    likes=142,
    view_count=1003
)
post2 = Post(
    id=str(uuid.uuid4()),
    author_id=user_peer.id,
    content="Super excited to publish this app to the App Store soon! E2E encryption + mesh networking out of the box. #RAVEN",
    timestamp=datetime.utcnow() - timedelta(hours=1),
    visibility="public",
    post_type="text",
    likes=289,
    view_count=2301
)
db.add(post1)
db.add(post2)
db.commit()
db.refresh(post1)
db.refresh(post2)

print("Creating comments...")
c1 = Comment(
    id=str(uuid.uuid4()),
    post_id=post1.id,
    author_id=user_sarah.id if user_sarah else user_peer.id,
    content="Can't wait for this release! The UX is extremely premium.",
    timestamp=datetime.utcnow() - timedelta(minutes=45),
    comment_type="text"
)
c2 = Comment(
    id=str(uuid.uuid4()),
    post_id=post2.id,
    author_id=user_main.id,
    content="The mesh routing speeds are insane.",
    timestamp=datetime.utcnow() - timedelta(minutes=20),
    comment_type="text"
)
db.add(c1)
db.add(c2)
db.commit()

print("Creating direct messages (mesh and internet)...")
messages = []
base_time = datetime.utcnow() - timedelta(minutes=30)

messages.append(Message(
    id=str(uuid.uuid4()),
    sender_id=user_peer.id,
    recipient_id=user_main.id,
    content="Hey! Is the App Store build ready?",
    timestamp=base_time,
    message_type="text",
    send_mode="internet"
))

messages.append(Message(
    id=str(uuid.uuid4()),
    sender_id=user_main.id,
    recipient_id=user_peer.id,
    content="Yep, everything has been finalized. We are doing the final UI captures today.",
    timestamp=base_time + timedelta(minutes=2),
    message_type="text",
    send_mode="internet"
))

messages.append(Message(
    id=str(uuid.uuid4()),
    sender_id=user_peer.id,
    recipient_id=user_main.id,
    content="Awesome. By the way, check out this message sent without internet!",
    timestamp=base_time + timedelta(minutes=4),
    message_type="text",
    send_mode="mesh"
))

messages.append(Message(
    id=str(uuid.uuid4()),
    sender_id=user_main.id,
    recipient_id=user_peer.id,
    content="Received! The local mesh router handled it perfectly.",
    timestamp=base_time + timedelta(minutes=5),
    message_type="text",
    send_mode="mesh"
))

for m in messages:
    db.add(m)

db.commit()
print("Mock data seeded successfully for A_Arezehgar and Main_Z3ous.")
db.close()
