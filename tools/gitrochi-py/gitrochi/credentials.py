"""API key lookup: an explicit environment variable first, then the OS store the Gitrochi apps already use.

macOS: Keychain generic password, service `com.ensnif.Gitrochi`, account `ai:<provider>` (macos/Sources/Services/Accounts.swift).
Windows: Credential Manager generic credential `ai:<provider>.Gitrochi` (keyring v3's default target for
service `Gitrochi`, user `ai:<provider>`; windows/src-tauri/src/system.rs).
Values are returned to the caller only; nothing here prints, logs or stores them.
"""

from __future__ import annotations

import os
import subprocess
import sys
from typing import Dict, List, Optional, Sequence, Tuple

MAC_SERVICE = "com.ensnif.Gitrochi"
WINDOWS_SERVICE = "Gitrochi"
GENERIC_ENV = "GITROCHI_AI_KEY"
PROVIDER_ENV: Dict[str, Tuple[str, ...]] = {
    "anthropic": ("ANTHROPIC_API_KEY",),
    "openai": ("OPENAI_API_KEY",),
    "gemini": ("GEMINI_API_KEY",),
    "compatible": (),
}


class KeyStore:
    """One place a key may come from. Tests replace these."""

    name = "store"

    def get(self, provider: str) -> Optional[str]:  # pragma: no cover - interface
        raise NotImplementedError


class EnvKeyStore(KeyStore):
    name = "environment"

    def __init__(self, environ: Optional[Dict[str, str]] = None):
        self.environ = os.environ if environ is None else environ

    def get(self, provider: str) -> Optional[str]:
        for var in PROVIDER_ENV.get(provider, ()) + (GENERIC_ENV,):
            value = self.environ.get(var, "").strip()
            if value:
                return value
        return None


class MacKeychainStore(KeyStore):
    name = "macOS Keychain"

    def __init__(self, timeout: float = 60):
        self.timeout = timeout

    def get(self, provider: str) -> Optional[str]:
        if sys.platform != "darwin":
            return None
        try:
            # The system may ask the user to allow `security` to read the app's item; a refusal is just "no key".
            proc = subprocess.run(["security", "find-generic-password", "-s", MAC_SERVICE, "-a", "ai:" + provider, "-w"],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=self.timeout)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if proc.returncode != 0:
            return None
        value = proc.stdout.decode("utf-8", "replace").strip()
        return value or None


def decode_credential_blob(blob: bytes) -> Optional[str]:
    """keyring v3 stores the password as UTF-16LE; other writers may have used UTF-8."""
    if not blob:
        return None
    if len(blob) % 2 == 0:
        try:
            text = blob.decode("utf-16-le")
            if "\x00" not in text:
                return text
        except UnicodeDecodeError:
            pass
    try:
        return blob.decode("utf-8")
    except UnicodeDecodeError:
        return None


class WindowsCredentialStore(KeyStore):
    name = "Windows Credential Manager"

    def get(self, provider: str) -> Optional[str]:
        if os.name != "nt":
            return None
        return read_windows_credential(f"ai:{provider}.{WINDOWS_SERVICE}")


def read_windows_credential(target: str) -> Optional[str]:  # pragma: no cover - Windows only
    import ctypes
    from ctypes import wintypes

    class FILETIME(ctypes.Structure):
        _fields_ = [("dwLowDateTime", wintypes.DWORD), ("dwHighDateTime", wintypes.DWORD)]

    class CREDENTIALW(ctypes.Structure):
        _fields_ = [
            ("Flags", wintypes.DWORD),
            ("Type", wintypes.DWORD),
            ("TargetName", wintypes.LPWSTR),
            ("Comment", wintypes.LPWSTR),
            ("LastWritten", FILETIME),
            ("CredentialBlobSize", wintypes.DWORD),
            ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
            ("Persist", wintypes.DWORD),
            ("AttributeCount", wintypes.DWORD),
            ("Attributes", ctypes.c_void_p),
            ("TargetAlias", wintypes.LPWSTR),
            ("UserName", wintypes.LPWSTR),
        ]

    cred_type_generic = 1
    try:
        advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    except OSError:
        return None
    cred_read = advapi32.CredReadW
    cred_read.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.POINTER(CREDENTIALW))]
    cred_read.restype = wintypes.BOOL
    cred_free = advapi32.CredFree
    cred_free.argtypes = [ctypes.c_void_p]
    cred_free.restype = None
    pointer = ctypes.POINTER(CREDENTIALW)()
    if not cred_read(target, cred_type_generic, 0, ctypes.byref(pointer)):
        return None
    try:
        cred = pointer.contents
        size = int(cred.CredentialBlobSize)
        blob = ctypes.string_at(cred.CredentialBlob, size) if size and cred.CredentialBlob else b""
        return decode_credential_blob(blob)
    finally:
        cred_free(pointer)


class ChainKeyStore(KeyStore):
    name = "chain"

    def __init__(self, stores: Sequence[KeyStore]):
        self.stores = list(stores)
        self.source: Optional[str] = None

    def get(self, provider: str) -> Optional[str]:
        for store in self.stores:
            value = store.get(provider)
            if value:
                self.source = store.name
                return value
        return None


def default_store(use_os_store: bool = True) -> ChainKeyStore:
    stores: List[KeyStore] = [EnvKeyStore()]
    if use_os_store and os.environ.get("GITROCHI_NO_KEYCHAIN", "").lower() not in ("1", "true", "yes"):
        stores += [MacKeychainStore(), WindowsCredentialStore()]
    return ChainKeyStore(stores)
