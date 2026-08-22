"""Tiny zero-dependency terminal styling for RDAP.

Colors auto-disable when not a TTY or when NO_COLOR is set (accessibility).
"""

from __future__ import annotations

import os
import sys

_ENABLED = sys.stdout.isatty() and os.environ.get('NO_COLOR') is None

_RESET = '\033[0m'


def _c(code: str, text) -> str:
    if not _ENABLED:
        return str(text)
    return f'\033[{code}m{text}{_RESET}'


def bold(t):   return _c('1', t)
def dim(t):    return _c('2', t)
def cyan(t):   return _c('96', t)
def green(t):  return _c('92', t)
def red(t):    return _c('91', t)
def yellow(t): return _c('93', t)


OK = '✔' if _ENABLED else '[ok]'
ERR = '✗' if _ENABLED else '[!!]'
ARROW = '→' if _ENABLED else '->'
DOT = '·' if _ENABLED else '-'


def header(title: str) -> None:
    line = '─' * max(4, 46 - len(title))
    print(f'\n{cyan(bold(f"── {title} "))}{cyan(line)}')


def ok(msg: str) -> None:
    print(green(OK) + f' {msg}')


def err(msg: str) -> None:
    print(red(ERR) + f' {msg}')


def warn(msg: str) -> None:
    print(yellow('!') + f' {msg}')


def box(lines: list[tuple[str, str]], title: str = '') -> None:
    """Render an aligned two-column status box."""
    KEY_W = 10
    rows = [(k.ljust(KEY_W), str(v)) for k, v in lines]
    w = max([len(k) + len(v) for k, v in rows] + [len(title)])
    print(cyan('┌' + '─' * (w + 2) + '┐'))
    if title:
        print(cyan('│ ') + bold(title.ljust(w)) + cyan(' │'))
        print(cyan('├' + '─' * (w + 2) + '┤'))
    for k, v in rows:
        print(cyan('│ ') + dim(k) + v + ' ' * (w - len(k) - len(v)) + cyan(' │'))
    print(cyan('└' + '─' * (w + 2) + '┘'))
