import models
from sqlalchemy import inspect

for name, obj in vars(models).items():
    if hasattr(obj, '__table__'):
        print(f"--- {name} ---")
        for col in inspect(obj).c:
            print(f"  {col.name}: {col.type}")
