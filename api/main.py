import base64
import hashlib
import hmac
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import HTMLResponse
from psycopg.rows import dict_row
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("mplayer-api")

DATABASE_URL = os.environ.get("DATABASE_URL", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin").strip().lower()
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
PORTAL_HTML = (Path(__file__).resolve().parent / "portal.html").read_text(encoding="utf-8")
SESSION_COOKIE = "mplayer_session"
SESSION_TTL = 14 * 24 * 60 * 60
USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,39}$")
CODE_RE = re.compile(r"^[A-Z0-9][A-Z0-9-]{2,31}$")


def connect():
    if not DATABASE_URL:
        raise RuntimeError("DATABASE_URL ausente")
    return psycopg.connect(DATABASE_URL, connect_timeout=10, row_factory=dict_row)


def hash_password(password: str) -> str:
    salt = os.urandom(16).hex()
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 120_000).hex()
    return f"{salt}${digest}"


def verify_password(password: str, stored: str) -> bool:
    salt, _, digest = stored.partition("$")
    if not salt or not digest:
        return False
    check = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 120_000).hex()
    return hmac.compare_digest(check, digest)


def issue_token(account_id: int, role: str, username: str) -> str:
    if not SESSION_SECRET:
        raise RuntimeError("SESSION_SECRET ausente")
    exp = int(time.time()) + SESSION_TTL
    payload = f"{account_id}|{role}|{username}|{exp}"
    signature = hmac.new(SESSION_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{payload}|{signature}".encode()).decode()


def read_token(token: str | None) -> dict | None:
    if not token or not SESSION_SECRET:
        return None
    try:
        raw = base64.urlsafe_b64decode(token.encode()).decode()
        account_id, role, username, exp, signature = raw.split("|")
        payload = f"{account_id}|{role}|{username}|{exp}"
        expected = hmac.new(SESSION_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return None
        if int(exp) < int(time.time()):
            return None
        if role not in {"admin", "partner"}:
            return None
        return {"id": int(account_id), "role": role, "username": username}
    except (ValueError, UnicodeError):
        return None


def current_user(request: Request) -> dict | None:
    return read_token(request.cookies.get(SESSION_COOKIE))


def require_user(request: Request, role: str | None = None) -> dict:
    user = current_user(request)
    if user is None:
        raise HTTPException(status_code=401, detail="faça login")
    if role and user["role"] != role:
        raise HTTPException(status_code=403, detail="sem permissão")
    return user


def normalize_code(value: str) -> str:
    code = value.strip().upper()
    if not CODE_RE.fullmatch(code):
        raise HTTPException(status_code=400, detail="código inválido: use letras, números e hífen")
    return code


def normalize_dns(value: str) -> str:
    dns = value.strip()
    if not (dns.startswith("http://") or dns.startswith("https://")):
        raise HTTPException(status_code=400, detail="a DNS precisa começar com http:// ou https://")
    if " " in dns or len(dns) > 300:
        raise HTTPException(status_code=400, detail="DNS inválida")
    return dns.rstrip("/")


def prepare_database():
    with connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS accounts (
                id BIGSERIAL PRIMARY KEY,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('admin', 'partner')),
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS partner_access (
                account_id BIGINT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                provider_code TEXT UNIQUE,
                dns_url TEXT,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        if ADMIN_PASSWORD and ADMIN_USERNAME:
            existing = conn.execute(
                "SELECT id FROM accounts WHERE role = 'admin' LIMIT 1"
            ).fetchone()
            if existing is None:
                conn.execute(
                    """
                    INSERT INTO accounts (username, password_hash, role)
                    VALUES (%s, %s, 'admin')
                    """,
                    (ADMIN_USERNAME, hash_password(ADMIN_PASSWORD)),
                )
                log.info("admin inicial criado")
        conn.commit()


def set_session(response: Response, user: dict):
    response.set_cookie(
        SESSION_COOKIE,
        issue_token(user["id"], user["role"], user["username"]),
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=SESSION_TTL,
        path="/",
    )


class LoginBody(BaseModel):
    username: str
    password: str


class PartnerCreateBody(BaseModel):
    username: str
    password: str


class AccessBody(BaseModel):
    provider_code: str
    dns_url: str


class PasswordBody(BaseModel):
    password: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    prepare_database()
    log.info("banco pronto")
    yield


app = FastAPI(title="mplayer API", lifespan=lifespan)


@app.get("/")
def root():
    return {
        "name": "mplayer",
        "service": "api",
        "health": "/health",
        "partner": "/partner",
        "admin": "/admin",
    }


@app.get("/health")
def health():
    try:
        with connect() as conn:
            row = conn.execute("SELECT now() AS time").fetchone()
        return {"status": "ok", "database": "up", "time": row["time"].isoformat()}
    except Exception:
        log.exception("falha ao consultar o banco")
        raise HTTPException(status_code=503, detail="banco indisponivel")


@app.get("/partner", response_class=HTMLResponse)
@app.get("/admin", response_class=HTMLResponse)
def portal_page():
    return HTMLResponse(PORTAL_HTML)


@app.post("/auth/login")
def login(body: LoginBody, response: Response):
    username = body.username.strip().lower()
    with connect() as conn:
        account = conn.execute(
            "SELECT id, username, password_hash, role FROM accounts WHERE username = %s",
            (username,),
        ).fetchone()
    if account is None or not verify_password(body.password, account["password_hash"]):
        raise HTTPException(status_code=401, detail="login ou senha incorretos")
    user = {"id": account["id"], "role": account["role"], "username": account["username"]}
    set_session(response, user)
    return {"username": user["username"], "role": user["role"]}


@app.post("/auth/logout")
def logout(response: Response):
    response.delete_cookie(SESSION_COOKIE, path="/")
    return {"ok": True}


@app.get("/auth/session")
def session(request: Request):
    user = current_user(request)
    if user is None:
        return {"authenticated": False}
    return {"authenticated": True, "username": user["username"], "role": user["role"]}


@app.get("/v1/partner-access/{code}")
def resolve_partner_access(code: str):
    normalized = code.strip().upper()
    if not CODE_RE.fullmatch(normalized):
        raise HTTPException(status_code=404, detail="código não encontrado")
    with connect() as conn:
        row = conn.execute(
            """
            SELECT dns_url
            FROM partner_access
            WHERE provider_code = %s AND dns_url IS NOT NULL AND dns_url <> ''
            """,
            (normalized,),
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="código não encontrado")
    return {"provider_code": normalized, "dns_url": row["dns_url"]}


@app.get("/partner/access")
def get_own_access(request: Request):
    user = require_user(request, "partner")
    with connect() as conn:
        row = conn.execute(
            "SELECT provider_code, dns_url FROM partner_access WHERE account_id = %s",
            (user["id"],),
        ).fetchone()
    return {
        "username": user["username"],
        "provider_code": (row or {}).get("provider_code") or "",
        "dns_url": (row or {}).get("dns_url") or "",
    }


@app.put("/partner/access")
def save_own_access(body: AccessBody, request: Request):
    user = require_user(request, "partner")
    code = normalize_code(body.provider_code)
    dns = normalize_dns(body.dns_url)
    try:
        with connect() as conn:
            conn.execute(
                """
                INSERT INTO partner_access (account_id, provider_code, dns_url)
                VALUES (%s, %s, %s)
                ON CONFLICT (account_id) DO UPDATE
                SET provider_code = EXCLUDED.provider_code,
                    dns_url = EXCLUDED.dns_url,
                    updated_at = now()
                """,
                (user["id"], code, dns),
            )
            conn.commit()
    except psycopg.errors.UniqueViolation:
        raise HTTPException(status_code=409, detail="esse código já está em uso")
    return {"provider_code": code, "dns_url": dns}


@app.get("/admin/partners")
def list_partners(request: Request):
    require_user(request, "admin")
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT a.id, a.username, a.created_at, p.provider_code, p.dns_url
            FROM accounts a
            LEFT JOIN partner_access p ON p.account_id = a.id
            WHERE a.role = 'partner'
            ORDER BY a.username
            """
        ).fetchall()
    return {
        "partners": [
            {
                "id": row["id"],
                "username": row["username"],
                "provider_code": row["provider_code"] or "",
                "dns_url": row["dns_url"] or "",
                "created_at": row["created_at"].isoformat(),
            }
            for row in rows
        ]
    }


@app.post("/admin/partners")
def create_partner(body: PartnerCreateBody, request: Request):
    require_user(request, "admin")
    username = body.username.strip().lower()
    if not USERNAME_RE.fullmatch(username):
        raise HTTPException(status_code=400, detail="usuário inválido")
    if len(body.password) < 6:
        raise HTTPException(status_code=400, detail="a senha precisa ter pelo menos 6 caracteres")
    try:
        with connect() as conn:
            row = conn.execute(
                """
                INSERT INTO accounts (username, password_hash, role)
                VALUES (%s, %s, 'partner')
                RETURNING id
                """,
                (username, hash_password(body.password)),
            ).fetchone()
            conn.execute(
                "INSERT INTO partner_access (account_id) VALUES (%s)",
                (row["id"],),
            )
            conn.commit()
    except psycopg.errors.UniqueViolation:
        raise HTTPException(status_code=409, detail="já existe um usuário com esse login")
    return {"id": row["id"], "username": username}


@app.put("/admin/partners/{account_id}")
def update_partner_access(account_id: int, body: AccessBody, request: Request):
    require_user(request, "admin")
    code = normalize_code(body.provider_code)
    dns = normalize_dns(body.dns_url)
    try:
        with connect() as conn:
            account = conn.execute(
                "SELECT id FROM accounts WHERE id = %s AND role = 'partner'",
                (account_id,),
            ).fetchone()
            if account is None:
                raise HTTPException(status_code=404, detail="parceiro não encontrado")
            conn.execute(
                """
                INSERT INTO partner_access (account_id, provider_code, dns_url)
                VALUES (%s, %s, %s)
                ON CONFLICT (account_id) DO UPDATE
                SET provider_code = EXCLUDED.provider_code,
                    dns_url = EXCLUDED.dns_url,
                    updated_at = now()
                """,
                (account_id, code, dns),
            )
            conn.commit()
    except psycopg.errors.UniqueViolation:
        raise HTTPException(status_code=409, detail="esse código já está em uso")
    return {"id": account_id, "provider_code": code, "dns_url": dns}


@app.put("/admin/partners/{account_id}/password")
def reset_partner_password(account_id: int, body: PasswordBody, request: Request):
    require_user(request, "admin")
    if len(body.password) < 6:
        raise HTTPException(status_code=400, detail="a senha precisa ter pelo menos 6 caracteres")
    with connect() as conn:
        updated = conn.execute(
            """
            UPDATE accounts
            SET password_hash = %s
            WHERE id = %s AND role = 'partner'
            RETURNING id
            """,
            (hash_password(body.password), account_id),
        ).fetchone()
        conn.commit()
    if updated is None:
        raise HTTPException(status_code=404, detail="parceiro não encontrado")
    return {"ok": True}


@app.delete("/admin/partners/{account_id}")
def delete_partner(account_id: int, request: Request):
    require_user(request, "admin")
    with connect() as conn:
        deleted = conn.execute(
            "DELETE FROM accounts WHERE id = %s AND role = 'partner' RETURNING id",
            (account_id,),
        ).fetchone()
        conn.commit()
    if deleted is None:
        raise HTTPException(status_code=404, detail="parceiro não encontrado")
    return {"ok": True}
