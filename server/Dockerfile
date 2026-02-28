FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies (curl for APNs HTTP/2 push)
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Cloud Run uses PORT environment variable
ENV PORT=8080

# Expose port
EXPOSE 8080

# Run uvicorn
CMD exec uvicorn main:app --host 0.0.0.0 --port $PORT --workers 1
