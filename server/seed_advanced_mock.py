import uuid
from datetime import datetime, timezone, timedelta
from database_config import SessionLocal
from models import User, Channel, ChannelMember, ChannelPost, Group, GroupMember, GroupMessage, Message

db = SessionLocal()

user_main = db.query(User).filter(User.username == "A_Arezehgar").first()
user_peer = db.query(User).filter(User.username == "Main_Z3ous").first()
user_sarah = db.query(User).filter(User.username == "Sarah_M").first()

if not user_main or not user_peer:
    print("Users A_Arezehgar or Main_Z3ous not found!")
    exit(1)

print("Creating Channels...")
channel_id = str(uuid.uuid4())
channel = Channel(
    id=channel_id,
    owner_id=user_main.id,
    channel_username="raven_updates",
    name="RAVEN Official",
    description="Official channel for RAVEN Mesh Messenger updates.",
    type="public",
    verified_status="verified",
    created_at=datetime.utcnow() - timedelta(days=2)
)
db.add(channel)

cm1 = ChannelMember(id=str(uuid.uuid4()), channel_id=channel_id, user_id=user_main.id, role="owner")
cm2 = ChannelMember(id=str(uuid.uuid4()), channel_id=channel_id, user_id=user_peer.id, role="member")
cm3 = ChannelMember(id=str(uuid.uuid4()), channel_id=channel_id, user_id=user_sarah.id, role="member" if user_sarah else "member")
db.add_all([cm1, cm2])
if user_sarah:
    db.add(cm3)

cp1 = ChannelPost(
    id=str(uuid.uuid4()),
    channel_id=channel_id,
    author_id=user_main.id,
    content_type="text",
    content_payload="Welcome to the official RAVEN channel! We are launching on the App Store soon! 🚀",
    created_at=datetime.utcnow() - timedelta(hours=12)
)
db.add(cp1)

print("Creating Groups...")
group_id = str(uuid.uuid4())
group = Group(
    id=group_id,
    name="iOS Beta Testers",
    description="Private group for mesh network beta testers.",
    created_by=user_peer.id,
    visibility="private"
)
db.add(group)

gm1 = GroupMember(id=str(uuid.uuid4()), group_id=group_id, user_id=user_peer.id, role="admin")
gm2 = GroupMember(id=str(uuid.uuid4()), group_id=group_id, user_id=user_main.id, role="member")
db.add_all([gm1, gm2])

gmsg1 = GroupMessage(
    id=str(uuid.uuid4()),
    group_id=group_id,
    sender_id=user_peer.id,
    content="Hey everyone! The latest TestFlight build looks solid.",
    message_type="text",
    timestamp=datetime.utcnow() - timedelta(minutes=60)
)
gmsg2 = GroupMessage(
    id=str(uuid.uuid4()),
    group_id=group_id,
    sender_id=user_main.id,
    content="I've attached the latest offline route debug logs.",
    message_type="text",
    timestamp=datetime.utcnow() - timedelta(minutes=15)
)
db.add_all([gmsg1, gmsg2])

print("Creating Voice Messages...")
vmsg = Message(
    id=str(uuid.uuid4()),
    sender_id=user_sarah.id if user_sarah else user_peer.id,
    recipient_id=user_main.id,
    content="",
    message_type="voice",
    audio_url="https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3",
    audio_duration_seconds=14,
    timestamp=datetime.utcnow() - timedelta(minutes=1),
    send_mode="internet"
)
db.add(vmsg)

db.commit()
print("Extended mock data (Channels, Groups, Voice) seeded successfully.")
db.close()
