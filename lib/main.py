from fastapi import FastAPI, UploadFile, File, HTTPException, Header
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import List, Dict, Any, Optional
import sqlite3, os, json, hashlib, uuid as _uuid
from datetime import datetime

app = FastAPI(title="Blue Sky Backend")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH  = os.path.join(BASE_DIR, "sync.db")
PDF_DIR  = os.path.join(BASE_DIR, "pdfs")
os.makedirs(PDF_DIR, exist_ok=True)

MASTER_USERNAME = "bluesky_master"
MASTER_PASSWORD = "BlueSky2026!Admin"   # change this after first deploy


def get_conn():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def _hash(p: str) -> str:
    return hashlib.sha256(p.encode()).hexdigest()


def init_db():
    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("BEGIN")

    cur.execute("""
        CREATE TABLE IF NOT EXISTS companies (
            company_id    TEXT PRIMARY KEY,
            username      TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            company_name  TEXT NOT NULL DEFAULT '',
            created_at    TEXT,
            invoice_count INTEGER NOT NULL DEFAULT 0
        )
    """)

    # Auth tokens for persistent login
    cur.execute("""
        CREATE TABLE IF NOT EXISTS auth_tokens (
            token         TEXT PRIMARY KEY,
            company_id    TEXT NOT NULL,
            created_at    TEXT NOT NULL,
            last_used_at  TEXT NOT NULL
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS events (
            seq          INTEGER,
            event_id     TEXT NOT NULL UNIQUE,
            company_id   TEXT NOT NULL,
            entity       TEXT NOT NULL,
            action       TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            PRIMARY KEY (seq, company_id)
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS invoice_numbers (
            company_id     TEXT NOT NULL,
            invoice_id     TEXT NOT NULL,
            invoice_number INTEGER NOT NULL,
            PRIMARY KEY (company_id, invoice_id)
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS invoice_seq (
            company_id    TEXT PRIMARY KEY,
            current_value INTEGER NOT NULL DEFAULT 0
        )
    """)
    # Ensure no sequence goes below 50 — next invoice will be at least 51
    cur.execute("UPDATE invoice_seq SET current_value=50 WHERE current_value < 50")

    cur.execute("COMMIT")
    conn.close()


def get_last_seq(cur, company_id: str) -> int:
    # Use global max seq so no two companies ever get the same seq value
    # This prevents PRIMARY KEY (seq, company_id) conflicts entirely
    cur.execute("SELECT COALESCE(MAX(seq), 0) AS ms FROM events")
    return int(cur.fetchone()["ms"])


def assign_invoice_number(cur, company_id: str, invoice_id: str) -> int:
    cur.execute(
        "SELECT invoice_number FROM invoice_numbers WHERE company_id=? AND invoice_id=?",
        (company_id, invoice_id))
    row = cur.fetchone()
    if row:
        return int(row["invoice_number"])
    # Seed at max(50, highest already-assigned number) so we never duplicate
    cur.execute("""
        INSERT OR IGNORE INTO invoice_seq (company_id, current_value)
        SELECT ?, MAX(50, COALESCE(MAX(invoice_number), 50))
        FROM invoice_numbers WHERE company_id=?
    """, (company_id, company_id))
    cur.execute("UPDATE invoice_seq SET current_value=current_value+1 WHERE company_id=?",
                (company_id,))
    cur.execute("SELECT current_value FROM invoice_seq WHERE company_id=?", (company_id,))
    num = int(cur.fetchone()["current_value"])
    cur.execute("INSERT INTO invoice_numbers VALUES (?,?,?)", (company_id, invoice_id, num))
    # Increment invoice counter on company
    cur.execute("UPDATE companies SET invoice_count=invoice_count+1 WHERE company_id=?",
                (company_id,))
    return num


def require_auth(x_username: Optional[str], x_password: Optional[str],
                 x_token: Optional[str], cur) -> str:
    """Returns company_id. Accepts either token or username+password."""
    # Token auth
    if x_token:
        cur.execute("SELECT company_id FROM auth_tokens WHERE token=?", (x_token,))
        row = cur.fetchone()
        if row:
            now = datetime.utcnow().isoformat()
            cur.execute("UPDATE auth_tokens SET last_used_at=? WHERE token=?", (now, x_token))
            return row["company_id"]

    # Username/password auth
    if x_username and x_password:
        cur.execute(
            "SELECT company_id FROM companies WHERE username=? AND password_hash=?",
            (x_username, _hash(x_password)))
        row = cur.fetchone()
        if row:
            return row["company_id"]

    raise HTTPException(status_code=401, detail="Invalid credentials or token")


def is_master(x_username: Optional[str], x_password: Optional[str]) -> bool:
    return x_username == MASTER_USERNAME and x_password == MASTER_PASSWORD


init_db()


# ── Health ────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


# ── Register ─────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    username:     str
    password:     str
    company_name: str

@app.post("/v1/auth/register")
def register(req: RegisterRequest):
    if len(req.username.strip()) < 3:
        raise HTTPException(400, "Username must be at least 3 characters")
    if len(req.password) < 6:
        raise HTTPException(400, "Password must be at least 6 characters")
    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("BEGIN")
    try:
        company_id = str(_uuid.uuid4())
        cur.execute(
            "INSERT INTO companies (company_id,username,password_hash,company_name,created_at,invoice_count) "
            "VALUES (?,?,?,?,?,0)",
            (company_id, req.username.strip().lower(),
             _hash(req.password), req.company_name.strip(),
             datetime.utcnow().isoformat()))
        # Issue a token immediately
        token = str(_uuid.uuid4())
        now   = datetime.utcnow().isoformat()
        cur.execute("INSERT INTO auth_tokens VALUES (?,?,?,?)",
                    (token, company_id, now, now))
        cur.execute("COMMIT")
        return {"success": True, "company_id": company_id,
                "company_name": req.company_name.strip(), "token": token}
    except sqlite3.IntegrityError:
        cur.execute("ROLLBACK")
        raise HTTPException(409, "Username already taken")
    finally:
        conn.close()


# ── Login ─────────────────────────────────────────────────────────────

@app.get("/v1/auth/login")
def login(x_username: Optional[str] = Header(None),
          x_password: Optional[str] = Header(None),
          x_token:    Optional[str] = Header(None)):
    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("BEGIN")
    try:
        company_id = require_auth(x_username, x_password, x_token, cur)
        cur.execute("SELECT company_name FROM companies WHERE company_id=?", (company_id,))
        row = cur.fetchone()

        # Issue / renew token
        token = str(_uuid.uuid4())
        now   = datetime.utcnow().isoformat()
        cur.execute("INSERT OR REPLACE INTO auth_tokens VALUES (?,?,?,?)",
                    (token, company_id, now, now))
        # Delete old tokens for this company (keep only latest 5)
        cur.execute("""
            DELETE FROM auth_tokens WHERE company_id=? AND token NOT IN (
                SELECT token FROM auth_tokens WHERE company_id=?
                ORDER BY last_used_at DESC LIMIT 5)
        """, (company_id, company_id))
        cur.execute("COMMIT")
        return {"success": True, "company_id": company_id,
                "company_name": row["company_name"] if row else "",
                "token": token}
    except HTTPException:
        cur.execute("ROLLBACK")
        raise
    finally:
        conn.close()


# ── Token refresh (silent re-auth) ───────────────────────────────────

@app.get("/v1/auth/refresh")
def refresh_token(x_token: Optional[str] = Header(None)):
    if not x_token:
        raise HTTPException(401, "No token")
    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("BEGIN")
    try:
        cur.execute("SELECT company_id FROM auth_tokens WHERE token=?", (x_token,))
        row = cur.fetchone()
        if not row:
            cur.execute("ROLLBACK")
            raise HTTPException(401, "Token expired or invalid")
        company_id = row["company_id"]
        now = datetime.utcnow().isoformat()
        cur.execute("UPDATE auth_tokens SET last_used_at=? WHERE token=?", (now, x_token))
        cur.execute("SELECT company_name FROM companies WHERE company_id=?", (company_id,))
        c = cur.fetchone()
        cur.execute("COMMIT")
        return {"success": True, "company_id": company_id,
                "company_name": c["company_name"] if c else ""}
    finally:
        conn.close()


# ── Master dashboard ─────────────────────────────────────────────────

@app.get("/v1/master/companies")
def master_companies(x_username: Optional[str] = Header(None),
                     x_password: Optional[str] = Header(None)):
    if not is_master(x_username, x_password):
        raise HTTPException(403, "Master access required")
    conn = get_conn()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT company_name, username, created_at, invoice_count
            FROM companies ORDER BY invoice_count DESC
        """)
        rows = cur.fetchall()
        return {"companies": [
            {"company_name": r["company_name"], "username": r["username"],
             "created_at": r["created_at"], "invoice_count": r["invoice_count"]}
            for r in rows
        ]}
    finally:
        conn.close()


@app.get("/v1/master/events")
def master_events(since_seq: int = 0,
                  x_username: Optional[str] = Header(None),
                  x_password: Optional[str] = Header(None)):
    """Returns ALL events from ALL companies for master view."""
    if not is_master(x_username, x_password):
        raise HTTPException(403, "Master access required")
    conn = get_conn()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT e.seq, e.event_id, e.company_id, e.entity, e.action,
                   e.payload_json, c.company_name
            FROM events e
            LEFT JOIN companies c ON c.company_id = e.company_id
            WHERE e.seq > ? ORDER BY e.seq ASC
        """, (since_seq,))
        rows = cur.fetchall()
        return {"events": [
            {"seq": r["seq"], "event_id": r["event_id"],
             "company_id": r["company_id"], "company_name": r["company_name"],
             "entity": r["entity"], "action": r["action"],
             "payload": json.loads(r["payload_json"])}
            for r in rows
        ]}
    finally:
        conn.close()




# ── Master: monthly breakdown for one company ────────────────────────

@app.get("/v1/master/company/{username}/monthly")
def master_company_monthly(username: str,
                            x_username: Optional[str] = Header(None),
                            x_password: Optional[str] = Header(None)):
    if not is_master(x_username, x_password):
        raise HTTPException(403, "Master access required")
    conn = get_conn()
    cur  = conn.cursor()
    try:
        cur.execute("SELECT company_id FROM companies WHERE username=?", (username,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "Company not found")
        company_id = row["company_id"]
        # Pull invoice upsert events and group by month using invoice_date in payload
        cur.execute("""
            SELECT payload_json FROM events
            WHERE company_id=? AND entity='invoice' AND action='upsert'
        """, (company_id,))
        from collections import defaultdict
        months: dict = defaultdict(lambda: {"invoice_count": 0, "total_cents": 0})
        seen_invoices: set = set()
        for r in cur.fetchall():
            try:
                p = json.loads(r["payload_json"])
                iid  = p.get("invoice_id") or p.get("id", "")
                date = (p.get("invoice_date") or "")[:7]   # "YYYY-MM"
                if not date or iid in seen_invoices:
                    continue
                seen_invoices.add(iid)
                months[date]["invoice_count"] += 1
                months[date]["total_cents"]   += p.get("amount_cents", 0)
            except Exception:
                continue
        result = sorted(
            [{"month": m, **v} for m, v in months.items()],
            key=lambda x: x["month"], reverse=True
        )
        return {"monthly": result}
    finally:
        conn.close()


# ── Master: reset a company's password ──────────────────────────────

class ResetPasswordRequest(BaseModel):
    username:     str
    new_password: str

@app.post("/v1/master/reset_password")
def master_reset_password(req: ResetPasswordRequest,
                           x_username: Optional[str] = Header(None),
                           x_password: Optional[str] = Header(None)):
    if not is_master(x_username, x_password):
        raise HTTPException(403, "Master access required")
    if len(req.new_password.strip()) < 6:
        raise HTTPException(400, "Password must be at least 6 characters")
    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("BEGIN")
    try:
        cur.execute("SELECT company_id FROM companies WHERE username=?", (req.username,))
        row = cur.fetchone()
        if not row:
            cur.execute("ROLLBACK")
            raise HTTPException(404, "Company not found")
        cur.execute("UPDATE companies SET password_hash=? WHERE username=?",
                    (_hash(req.new_password.strip()), req.username))
        # Invalidate all existing tokens for this company
        cur.execute("DELETE FROM auth_tokens WHERE company_id=?", (row["company_id"],))
        cur.execute("COMMIT")
        return {"success": True, "username": req.username}
    except HTTPException:
        cur.execute("ROLLBACK")
        raise
    finally:
        conn.close()


# ── Master: delete a company and all their data ──────────────────────

@app.delete("/v1/master/company/{username}")
def master_delete_company(username: str,
                           x_username: Optional[str] = Header(None),
                           x_password: Optional[str] = Header(None)):
    if not is_master(x_username, x_password):
        raise HTTPException(403, "Master access required")
    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("BEGIN")
    try:
        cur.execute("SELECT company_id FROM companies WHERE username=?", (username,))
        row = cur.fetchone()
        if not row:
            cur.execute("ROLLBACK")
            raise HTTPException(404, "Company not found")
        company_id = row["company_id"]
        cur.execute("DELETE FROM events          WHERE company_id=?", (company_id,))
        cur.execute("DELETE FROM invoice_numbers WHERE company_id=?", (company_id,))
        cur.execute("DELETE FROM invoice_seq     WHERE company_id=?", (company_id,))
        cur.execute("DELETE FROM auth_tokens     WHERE company_id=?", (company_id,))
        cur.execute("DELETE FROM companies       WHERE company_id=?", (company_id,))
        # Remove uploaded PDFs from disk
        import shutil
        pdf_dir = os.path.join(PDF_DIR, company_id)
        if os.path.isdir(pdf_dir):
            shutil.rmtree(pdf_dir, ignore_errors=True)
        cur.execute("COMMIT")
        return {"success": True, "username": username, "company_id": company_id}
    except HTTPException:
        cur.execute("ROLLBACK")
        raise
    finally:
        conn.close()


# ── Master: clear test data for one company (keep invoice sequence) ──

@app.delete("/v1/master/company/{username}/events")
def master_clear_events(username: str,
                         x_username: Optional[str] = Header(None),
                         x_password: Optional[str] = Header(None)):
    if not is_master(x_username, x_password):
        raise HTTPException(403, "Master access required")
    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("BEGIN")
    try:
        cur.execute("SELECT company_id FROM companies WHERE username=?", (username,))
        row = cur.fetchone()
        if not row:
            cur.execute("ROLLBACK")
            raise HTTPException(404, "Company not found")
        company_id = row["company_id"]
        cur.execute("SELECT COUNT(*) AS cnt FROM events WHERE company_id=?", (company_id,))
        deleted = cur.fetchone()["cnt"]
        cur.execute("DELETE FROM events          WHERE company_id=?", (company_id,))
        cur.execute("DELETE FROM invoice_numbers WHERE company_id=?", (company_id,))
        cur.execute("UPDATE companies SET invoice_count=0 WHERE company_id=?", (company_id,))
        # Preserve invoice_seq so next real invoice continues from where it left off
        cur.execute("SELECT current_value FROM invoice_seq WHERE company_id=?", (company_id,))
        seq_row = cur.fetchone()
        invoice_sequence = seq_row["current_value"] if seq_row else 0
        cur.execute("COMMIT")
        return {"success": True, "events_deleted": deleted,
                "invoice_sequence": invoice_sequence}
    except HTTPException:
        cur.execute("ROLLBACK")
        raise
    finally:
        conn.close()



# ── Delete invoice ────────────────────────────────────────────────────

@app.delete("/v1/invoices/{invoice_id}")
def delete_invoice(invoice_id: str,
                   x_username: Optional[str] = Header(None),
                   x_password: Optional[str] = Header(None),
                   x_token:    Optional[str] = Header(None)):
    conn = get_conn()
    cur  = conn.cursor()
    company_id = require_auth(x_username, x_password, x_token, cur)
    cur.execute("BEGIN")
    try:
        # Push a delete tombstone event so other devices sync the deletion
        last_seq = get_last_seq(cur, company_id)
        last_seq += 1
        event_id = str(_uuid.uuid4())
        payload  = json.dumps({"invoice_id": invoice_id})
        cur.execute(
            "INSERT INTO events (seq,event_id,company_id,entity,action,payload_json) "
            "VALUES (?,?,?,?,?,?)",
            (last_seq, event_id, company_id, "invoice", "delete", payload))
        # Remove the invoice's own upsert events so re-pulls don't resurrect it
        cur.execute(
            "DELETE FROM events WHERE company_id=? AND entity='invoice' "
            "AND action IN ('upsert','finalize') "
            "AND json_extract(payload_json,'$.invoice_id')=?",
            (company_id, invoice_id))
        # Clean up invoice number record
        cur.execute(
            "DELETE FROM invoice_numbers WHERE company_id=? AND invoice_id=?",
            (company_id, invoice_id))
        # Decrement invoice counter
        cur.execute(
            "UPDATE companies SET invoice_count=MAX(0,invoice_count-1) WHERE company_id=?",
            (company_id,))
        # Remove PDF if stored on server
        import shutil as _shutil
        pdf_path = os.path.join(PDF_DIR, company_id, f"{invoice_id}.pdf")
        if os.path.exists(pdf_path):
            try: os.remove(pdf_path)
            except Exception: pass
        cur.execute("COMMIT")
        return {"success": True, "invoice_id": invoice_id}
    except HTTPException:
        cur.execute("ROLLBACK"); raise
    except Exception as exc:
        cur.execute("ROLLBACK"); raise HTTPException(500, str(exc))
    finally:
        conn.close()


# ── Delete customer (and all their data) ─────────────────────────────

@app.delete("/v1/customers/{customer_id}")
def delete_customer(customer_id: str,
                    x_username: Optional[str] = Header(None),
                    x_password: Optional[str] = Header(None),
                    x_token:    Optional[str] = Header(None)):
    conn = get_conn()
    cur  = conn.cursor()
    company_id = require_auth(x_username, x_password, x_token, cur)
    cur.execute("BEGIN")
    try:
        # Find all invoice_ids for this customer from events
        cur.execute(
            "SELECT DISTINCT json_extract(payload_json,'$.invoice_id') AS iid "
            "FROM events WHERE company_id=? AND entity='invoice' "
            "AND json_extract(payload_json,'$.customer_id')=?",
            (company_id, customer_id))
        invoice_ids = [r["iid"] for r in cur.fetchall() if r["iid"]]

        # Push delete tombstones for each invoice
        last_seq = get_last_seq(cur, company_id)
        for iid in invoice_ids:
            last_seq += 1
            cur.execute(
                "INSERT INTO events (seq,event_id,company_id,entity,action,payload_json) "
                "VALUES (?,?,?,?,?,?)",
                (last_seq, str(_uuid.uuid4()), company_id,
                 "invoice", "delete", json.dumps({"invoice_id": iid})))
            cur.execute(
                "DELETE FROM invoice_numbers WHERE company_id=? AND invoice_id=?",
                (company_id, iid))
            pdf_path = os.path.join(PDF_DIR, company_id, f"{iid}.pdf")
            if os.path.exists(pdf_path):
                try: os.remove(pdf_path)
                except Exception: pass

        # Push customer delete tombstone
        last_seq += 1
        cur.execute(
            "INSERT INTO events (seq,event_id,company_id,entity,action,payload_json) "
            "VALUES (?,?,?,?,?,?)",
            (last_seq, str(_uuid.uuid4()), company_id,
             "customer", "delete", json.dumps({"customer_id": customer_id})))

        # Remove all events for this customer and their invoices
        cur.execute(
            "DELETE FROM events WHERE company_id=? AND entity IN ('invoice','invoice_item') "
            "AND json_extract(payload_json,'$.customer_id')=?",
            (company_id, customer_id))
        cur.execute(
            "DELETE FROM events WHERE company_id=? AND entity='customer' "
            "AND json_extract(payload_json,'$.customer_id')=?",
            (company_id, customer_id))
        cur.execute(
            "UPDATE companies SET invoice_count=MAX(0,invoice_count-?) WHERE company_id=?",
            (len(invoice_ids), company_id))

        cur.execute("COMMIT")
        return {"success": True, "customer_id": customer_id,
                "invoices_deleted": len(invoice_ids)}
    except HTTPException:
        cur.execute("ROLLBACK"); raise
    except Exception as exc:
        cur.execute("ROLLBACK"); raise HTTPException(500, str(exc))
    finally:
        conn.close()

# ── Sync Models ───────────────────────────────────────────────────────

class Event(BaseModel):
    event_id: str
    seq:      int
    entity:   str
    action:   str
    payload:  Dict[str, Any]

class PushRequest(BaseModel):
    device_id: str
    events:    List[Event]


# ── Push ─────────────────────────────────────────────────────────────

@app.post("/v1/sync/push")
def sync_push(request: PushRequest,
              x_username: Optional[str] = Header(None),
              x_password: Optional[str] = Header(None),
              x_token:    Optional[str] = Header(None)):
    conn = get_conn()
    cur  = conn.cursor()
    # Auth check BEFORE opening transaction so 401 doesn't get swallowed
    company_id = require_auth(x_username, x_password, x_token, cur)
    cur.execute("BEGIN")
    try:
        last_seq   = get_last_seq(cur, company_id)
        stored = ignored = 0

        for e in request.events:
            cur.execute("SELECT 1 FROM events WHERE event_id=? LIMIT 1", (e.event_id,))
            if cur.fetchone():
                ignored += 1
                continue
            last_seq += 1
            payload = e.payload.copy()
            if e.entity == "invoice" and e.action == "upsert":
                iid = payload.get("invoice_id") or payload.get("id", "")
                if iid:
                    payload["invoice_number"] = assign_invoice_number(
                        cur, company_id, iid)
            cur.execute(
                "INSERT INTO events (seq,event_id,company_id,entity,action,payload_json) "
                "VALUES (?,?,?,?,?,?)",
                (last_seq, e.event_id, company_id,
                 e.entity, e.action, json.dumps(payload)))
            stored += 1

        cur.execute("COMMIT")
        return {"success": True, "stored_events": stored,
                "ignored_duplicates": ignored, "last_seq": last_seq}
    except HTTPException:
        cur.execute("ROLLBACK")
        raise
    except Exception as exc:
        cur.execute("ROLLBACK")
        raise HTTPException(500, str(exc))
    finally:
        conn.close()


# ── Pull ─────────────────────────────────────────────────────────────

@app.get("/v1/sync/pull/{device_id}")
def sync_pull(device_id: str, since_seq: int = 0,
              x_username: Optional[str] = Header(None),
              x_password: Optional[str] = Header(None),
              x_token:    Optional[str] = Header(None)):
    conn = get_conn()
    cur  = conn.cursor()
    company_id = require_auth(x_username, x_password, x_token, cur)
    try:
        cur.execute(
            "SELECT seq,event_id,entity,action,payload_json FROM events "
            "WHERE company_id=? AND seq>? ORDER BY seq ASC",
            (company_id, since_seq))
        rows     = cur.fetchall()
        last_seq = get_last_seq(cur, company_id)
        events   = [{"event_id": r["event_id"], "seq": int(r["seq"]),
                     "entity": r["entity"], "action": r["action"],
                     "payload": json.loads(r["payload_json"])}
                    for r in rows]
        return {"success": True, "events": events, "last_seq": last_seq}
    finally:
        conn.close()


# ── PDF ───────────────────────────────────────────────────────────────

@app.post("/v1/invoices/{invoice_id}/pdf")
async def upload_pdf(invoice_id: str, file: UploadFile = File(...),
                     x_username: Optional[str] = Header(None),
                     x_password: Optional[str] = Header(None),
                     x_token:    Optional[str] = Header(None)):
    conn = get_conn()
    cur  = conn.cursor()
    try:
        company_id = require_auth(x_username, x_password, x_token, cur)
    finally:
        conn.close()
    company_dir = os.path.join(PDF_DIR, company_id)
    os.makedirs(company_dir, exist_ok=True)
    contents = await file.read()
    if not contents:
        raise HTTPException(400, "Empty file")
    with open(os.path.join(company_dir, f"{invoice_id}.pdf"), "wb") as f:
        f.write(contents)
    return {"success": True, "size_bytes": len(contents)}


@app.get("/v1/invoices/{invoice_id}/pdf")
def download_pdf(invoice_id: str,
                 x_username: Optional[str] = Header(None),
                 x_password: Optional[str] = Header(None),
                 x_token:    Optional[str] = Header(None)):
    conn = get_conn()
    cur  = conn.cursor()
    try:
        company_id = require_auth(x_username, x_password, x_token, cur)
    finally:
        conn.close()
    pdf_path = os.path.join(PDF_DIR, company_id, f"{invoice_id}.pdf")
    if not os.path.exists(pdf_path):
        raise HTTPException(404, "PDF not found")
    return FileResponse(path=pdf_path, media_type="application/pdf",
                        filename=f"invoice_{invoice_id}.pdf")