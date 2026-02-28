"""
Logging Configuration with Sensitive Data Filtering
Prevents sensitive information from appearing in logs
"""
import logging
import re
from typing import Pattern, List, Tuple


class SensitiveDataFilter(logging.Filter):
    """
    Filter that redacts sensitive data from log messages
    
    Redacts:
    - JWT tokens (Bearer tokens)
    - Passwords
    - API keys
    - Email addresses
    - Phone numbers
    - Credit card numbers
    - Session tokens
    """
    
    # Regex patterns for sensitive data
    PATTERNS: List[Tuple[Pattern, str]] = [
        # JWT Tokens (Bearer token format)
        (re.compile(r'Bearer\s+[\w-]+\.[\w-]+\.[\w-]+'), 'Bearer [REDACTED_JWT]'),
        
        # Generic tokens
        (re.compile(r'"token"\s*:\s*"[^"]*"'), '"token": "[REDACTED]"'),
        (re.compile(r"'token'\s*:\s*'[^']*'"), "'token': '[REDACTED]'"),
        
        # Passwords
        (re.compile(r'"password"\s*:\s*"[^"]*"'), '"password": "[REDACTED]"'),
        (re.compile(r"'password'\s*:\s*'[^']*'"), "'password': '[REDACTED]'"),
        (re.compile(r'password=\w+'), 'password=[REDACTED]'),
        
        # API Keys
        (re.compile(r'"api_key"\s*:\s*"[^"]*"'), '"api_key": "[REDACTED]"'),
        (re.compile(r'api[_-]?key=[a-zA-Z0-9_-]+', re.IGNORECASE), 'api_key=[REDACTED]'),
        
        # Email addresses
        (re.compile(r'\b[\w.-]+@[\w.-]+\.\w+\b'), '[EMAIL_REDACTED]'),
        
        # Phone numbers (international format)
        (re.compile(r'\+?[1-9]\d{9,14}\b'), '[PHONE_REDACTED]'),
        
        # Credit card numbers (basic pattern)
        (re.compile(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'), '[CARD_REDACTED]'),
        
        # Session IDs / UUIDs in sensitive contexts
        (re.compile(r'session[_-]?id[=:]\s*[a-f0-9-]{32,}', re.IGNORECASE), 'session_id=[REDACTED]'),
        
        # Authorization headers
        (re.compile(r'Authorization:\s*.+'), 'Authorization: [REDACTED]'),
        
        # Cookies with sensitive data
        (re.compile(r'Cookie:\s*.+'), 'Cookie: [REDACTED]'),
        
        # ✅ SECURITY FIX: IP addresses (prevents user tracking via logs)
        (re.compile(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'), '[IP_REDACTED]'),
        (re.compile(r'ip[=:]\s*\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}', re.IGNORECASE), 'ip=[REDACTED]'),
        
        # ✅ SECURITY FIX: User IDs (prevents correlation attacks)
        (re.compile(r'user[_-]?id[=:]\s*[a-f0-9-]{32,}', re.IGNORECASE), 'user_id=[REDACTED]'),
        (re.compile(r'"user_id"\s*:\s*"[a-f0-9-]+"'), '"user_id": "[REDACTED]"'),
    ]

    
    def filter(self, record: logging.LogRecord) -> bool:
        """
        Filter log record to redact sensitive data
        
        Args:
            record: Log record to filter
            
        Returns:
            bool: Always True (we modify but don't block the record)
        """
        # Get the original message
        original_message = record.getMessage()
        
        # Apply all redaction patterns
        filtered_message = original_message
        for pattern, replacement in self.PATTERNS:
            filtered_message = pattern.sub(replacement, filtered_message)
        
        # Update the record's message
        record.msg = filtered_message
        record.args = ()  # Clear args since we've already formatted
        
        return True


def configure_secure_logging(
    level: int = logging.INFO,
    format_string: str = '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
) -> None:
    """
    Configure logging with sensitive data filtering
    
    Args:
        level: Logging level (default: INFO)
        format_string: Log format string
    """
    # Get root logger
    logger = logging.getLogger()
    logger.setLevel(level)
    
    # Remove existing handlers
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)
    
    # Create console handler
    console_handler = logging.StreamHandler()
    console_handler.setLevel(level)
    
    # Create formatter
    formatter = logging.Formatter(format_string)
    console_handler.setFormatter(formatter)
    
    # Add sensitive data filter
    console_handler.addFilter(SensitiveDataFilter())
    
    # Add handler to logger
    logger.addHandler(console_handler)
    
    print("✅ Secure logging configured with sensitive data filtering")


# Example usage
if __name__ == "__main__":
    # Configure secure logging
    configure_secure_logging()
    
    # Test logger
    logger = logging.getLogger(__name__)
    
    # These should be redacted
    logger.info("User login with password=secretpass123")
    logger.info("JWT token: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U")
    logger.info("Email: user@example.com, Phone: +1234567890")
    logger.info("Credit card: 4532-1234-5678-9010")
    
    # This should NOT be redacted
    logger.info("User logged in successfully")
    logger.info("Post created with ID: 12345")
