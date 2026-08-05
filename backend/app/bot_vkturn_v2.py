from __future__ import annotations

import asyncio, base64, json, subprocess, uuid
from datetime import UTC, datetime, timedelta
from html import escape

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message
from sqlalchemy import select

from .config import get_settings
from .db import SessionLocal
from .models import AuditLog, VkTurnAccess, VkTurnSetting

router = Router(name="vkturn-management-v2")

class Create(StatesGroup):
    telegram_id = State(); note = State()
class SetLink(StatesGroup):
    value = State()

def b(t,d): return InlineKeyboardButton(text=t, callback_data=d)
def kb(rows): return InlineKeyboardMarkup(inline_keyboard=rows)
def owner(uid):
    s=get_settings(); return bool(uid and s.telegram_owner_id and uid==s.telegram_owner_id)
def run(*args, input_text=None):
    return subprocess.run(args,input=input_text,text=True,check=True,capture_output=True).stdout.strip()
def keypair():
    private=run("wg","genkey"); return private,run("wg","pubkey",input_text=private+"\n")
def add_peer(key,ip): run("wg","set","wg0","peer",key,"allowed-ips",f"{ip}/32")
def remove_peer(key):
    try: run("wg","set","wg0","peer",key,"remove")
    except Exception: pass
def server_key(): return run("wg","show","wg0","public-key")

def make_link(row, vk_link):
    endpoint=getattr(get_settings(),"vkturn_public_endpoint","31.77.148.80:56100")
    settings={"serverName":f"DarkTunnel VK #{str(row.id)[:8]}","privateKey":row.private_key,"peerPublicKey":server_key(),"tunnelAddress":f"{row.tunnel_ip}/24","dnsServers":"1.1.1.1","vkLink":vk_link,"peerAddress":endpoint,"numConnections":30,"useDTLS":True,"useWrap":False,"wrapKeyHex":"","useSrtp":True,"useUDP":False,"useWrapA":False,"useWrapS":False,"obfProfile":"rtpopus","clientID":""}
    payload={"version":1,"type":"connection","settings":settings}
    raw=json.dumps(payload,separators=(",",":"),sort_keys=True).encode()
    return "vkturnproxy://import?data="+base64.urlsafe_b64encode(raw).decode().rstrip("=")

async def edit(c,text,rows):
    if c.message: await c.message.edit_text(text,reply_markup=kb(rows),parse_mode="HTML")
    await c.answer()
async def get_row(ident):
    async with SessionLocal() as s: return await s.get(VkTurnAccess,uuid.UUID(ident))
async def render(c,ident):
    async with SessionLocal() as s:
        row=await s.get(VkTurnAccess,uuid.UUID(ident)); setting=await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key=="vk_link"))
    if not row: await c.answer("Не найдено",show_alert=True); return
    active=not row.revoked_at and row.expires_at>datetime.now(UTC)
    rows=[[b("➕ 30 дней",f"vk2:extend:{row.id}")],[b("⛔️ Отключить" if active else "✅ Включить",f"vk2:toggle:{row.id}")]]
    if setting and setting.value: rows.append([b("🔗 Показать ссылку",f"vk2:show:{row.id}")])
    rows.append([b("⬅️ VK Turn","vkturn")])
    await edit(c,f"<b>VK Turn доступ</b>\n\nID: <code>{row.id}</code>\nTelegram: <code>{row.telegram_id or '—'}</code>\nЗаметка: {escape(row.note or '—')}\nIP: <code>{row.tunnel_ip}</code>\nДо: <b>{row.expires_at.astimezone().strftime('%d.%m.%Y %H:%M')}</b>\nСтатус: <b>{'активен' if active else 'отключён'}</b>",rows)

@router.callback_query(F.data=="vkturn")
async def menu(c):
    if not owner(c.from_user.id): await c.answer("Доступ запрещён",show_alert=True); return
    async with SessionLocal() as s:
        rows=(await s.execute(select(VkTurnAccess).order_by(VkTurnAccess.created_at.desc()).limit(20))).scalars().all(); setting=await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key=="vk_link"))
    now=datetime.now(UTC); buttons=[[b("➕ 3 дня","vk2:new:3"),b("➕ 30 дней","vk2:new:30")],[b("🔗 Задать VK-звонок","vk2:set-link")]]
    for row in rows:
        active=not row.revoked_at and row.expires_at>now; buttons.append([b(f"{'✅' if active else '❌'} {row.note or str(row.telegram_id or row.id)[:16]}",f"vk2:view:{row.id}")])
    buttons.append([b("⬅️ Главное меню","home")]); await edit(c,f"<b>📡 VK Turn Proxy</b>\n\nVK-звонок: <b>{'настроен' if setting and setting.value else 'не задан'}</b>\nДоступы отдельны от DarkTurn.",buttons)

@router.callback_query(F.data.startswith("vk2:new:"))
async def new(c,state:FSMContext):
    if not owner(c.from_user.id): return
    await state.set_state(Create.telegram_id); await state.update_data(days=int(c.data.rsplit(":",1)[1])); await edit(c,"Отправьте Telegram ID пользователя или 0.",[[b("❌ Отмена","vkturn")]])
@router.message(Create.telegram_id)
async def new_tg(m,state:FSMContext):
    if not owner(m.from_user.id if m.from_user else None): return
    try: tid=int((m.text or "0").strip())
    except ValueError: tid=-1
    if tid<0: await m.answer("Введите числовой Telegram ID или 0."); return
    await state.update_data(telegram_id=tid or None); await state.set_state(Create.note); await m.answer("Отправьте заметку/имя пользователя.")
@router.message(Create.note)
async def finish(m,state:FSMContext):
    if not owner(m.from_user.id if m.from_user else None): return
    data=await state.get_data(); await state.clear(); private,public=keypair()
    async with SessionLocal() as s:
        setting=await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key=="vk_link"))
        if not setting or not setting.value: await m.answer("Сначала задайте ссылку VK-звонка."); return
        used=set((await s.execute(select(VkTurnAccess.tunnel_ip))).scalars().all()); ip=next((f"10.79.0.{i}" for i in range(2,255) if f"10.79.0.{i}" not in used),None)
        if not ip: await m.answer("Свободные адреса закончились."); return
        row=VkTurnAccess(telegram_id=data.get("telegram_id"),note=(m.text or "")[:200],private_key=private,public_key=public,tunnel_ip=ip,expires_at=datetime.now(UTC)+timedelta(days=int(data["days"])))
        s.add(row); await s.flush(); s.add(AuditLog(admin_id=m.from_user.id,action="vkturn.create",entity_type="vkturn_access",entity_id=str(row.id))); await s.commit(); await s.refresh(row); vk=setting.value
    add_peer(public,ip); await m.answer(f"<b>✅ VK Turn доступ создан</b>\n\nДо: <b>{row.expires_at.astimezone().strftime('%d.%m.%Y %H:%M')}</b>\n\n<code>{escape(make_link(row,vk))}</code>",reply_markup=kb([[b("📡 К VK Turn","vkturn")]]),parse_mode="HTML")

@router.callback_query(F.data=="vk2:set-link")
async def set_start(c,state:FSMContext): await state.set_state(SetLink.value); await edit(c,"Отправьте полную ссылку VK-звонка.",[[b("❌ Отмена","vkturn")]])
@router.message(SetLink.value)
async def set_finish(m,state:FSMContext):
    value=(m.text or "").strip()
    if not value.startswith("http") or not ("/call/" in value or "vk.me/join/" in value): await m.answer("Это не похоже на ссылку VK-звонка."); return
    async with SessionLocal() as s:
        row=await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key=="vk_link")); row.value=value if row else value
        if not row: s.add(VkTurnSetting(key="vk_link",value=value))
        await s.commit()
    await state.clear(); await m.answer("✅ Ссылка сохранена.",reply_markup=kb([[b("📡 VK Turn","vkturn")]]))
@router.callback_query(F.data.startswith("vk2:view:"))
async def view(c): await render(c,c.data.rsplit(":",1)[1])
@router.callback_query(F.data.startswith("vk2:extend:"))
async def extend(c):
    ident=c.data.rsplit(":",1)[1]
    async with SessionLocal() as s:
        row=await s.get(VkTurnAccess,uuid.UUID(ident)); row.expires_at=max(row.expires_at,datetime.now(UTC))+timedelta(days=30); row.revoked_at=None; await s.commit(); key,ip=row.public_key,row.tunnel_ip
    add_peer(key,ip); await render(c,ident)
@router.callback_query(F.data.startswith("vk2:toggle:"))
async def toggle(c):
    ident=c.data.rsplit(":",1)[1]
    async with SessionLocal() as s:
        row=await s.get(VkTurnAccess,uuid.UUID(ident)); enable=bool(row.revoked_at)
        if enable:
            row.revoked_at=None
            if row.expires_at<=datetime.now(UTC): row.expires_at=datetime.now(UTC)+timedelta(days=30)
        else: row.revoked_at=datetime.now(UTC)
        await s.commit(); key,ip=row.public_key,row.tunnel_ip
    add_peer(key,ip) if enable else remove_peer(key); await render(c,ident)
@router.callback_query(F.data.startswith("vk2:show:"))
async def show(c):
    ident=c.data.rsplit(":",1)[1]
    async with SessionLocal() as s:
        row=await s.get(VkTurnAccess,uuid.UUID(ident)); setting=await s.scalar(select(VkTurnSetting).where(VkTurnSetting.key=="vk_link"))
    if row and setting and setting.value and c.message: await c.message.answer(f"<code>{escape(make_link(row,setting.value))}</code>",parse_mode="HTML")
    await c.answer()

async def sync_peers_forever():
    while True:
        try:
            async with SessionLocal() as s: rows=(await s.execute(select(VkTurnAccess))).scalars().all()
            now=datetime.now(UTC)
            for row in rows: remove_peer(row.public_key) if row.revoked_at or row.expires_at<=now else add_peer(row.public_key,row.tunnel_ip)
        except Exception: pass
        await asyncio.sleep(60)
