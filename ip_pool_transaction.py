"""Resumable application contract. Adapter methods must reconcile by intent ID.

Persist each successful step before the next. A failed/ambiguous call leaves the
step pending: the adapter reads back owned resources before any repeated write.
"""
import time

STEPS = {
    'enable': ('prepare', 'verify', 'publish', 'confirm'),
    'replace': ('prepare', 'verify', 'publish', 'confirm', 'hide_old', 'stop_old'),
    'disable': ('hide_old', 'confirm_hidden', 'stop_old'),
    'hide': ('hide_old', 'confirm_hidden', 'stop_old'),
}


def execute(pool, intent_id, adapter, persist, now=None):
    """Caller holds the installer lock for the entire transaction.

    adapter.validate checks current IP ownership, source-bound egress, resource
    ownership and server-scoped authority. All steps are idempotent/read-back.
    confirm verifies publication and actual external transfer before retiring old.
    """
    now = time.time() if now is None else now
    intent = next(x for x in pool['intents'] if x['id'] == intent_id)
    if intent['status'] != 'pending':
        return False
    if intent['actor']=='automatic' and pool['paused']:
        return False
    if any(pool['addresses'][ip].get('locked') for ip in (intent['old'],intent['new']) if ip):
        return False
    adapter.validate(pool, intent)
    completed=intent.setdefault('completed',[])
    for step in STEPS[intent['action']]:
        if step in completed:
            continue
        # An exception here must not set completion or retire the old entry.
        getattr(adapter,step)(pool,intent)
        completed.append(step)
        persist(pool)
    if intent['old']:
        old=pool['addresses'][intent['old']]
        old['mode']='disabled' if intent['action']=='disable' else 'retired'
        old['cooldown_until']=now+3600
    if intent['new']:
        new=pool['addresses'][intent['new']]
        new['mode']='active'
        new['cooldown_until']=now+3600
    intent.update(status='complete',completed_at=now)
    # Bound completed history, but never discard pending recovery journals.
    unfinished={'pending','cleanup_required'}
    finished=[x for x in pool['intents'] if x['status'] not in unfinished][-100:]
    pool['intents']=[x for x in pool['intents'] if x['status'] in unfinished]+finished
    persist(pool)
    return True
