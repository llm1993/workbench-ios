"""Validate native request examples against the actual local Pydantic schemas.
No application is imported, no DB is opened, and no HTTP request is sent.
"""
import ast
from datetime import date
from decimal import Decimal
import importlib.util
from pathlib import Path
import sys
import types
from typing import Literal
from pydantic import BaseModel, Field, StrictInt, ValidationError

root=Path(__file__).resolve().parents[1]
backend=root.parent/'workbench/backend/app'
spec=importlib.util.spec_from_file_location('native_contract_schemas',backend/'schemas.py')
schemas=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=schemas
spec.loader.exec_module(schemas)

def classes(file,names,aliases=()):
    source=ast.parse((backend/'routers'/file).read_text(encoding='utf-8-sig'))
    body=[]
    for node in source.body:
        if isinstance(node,ast.ClassDef) and node.name in names:body.append(node)
        elif isinstance(node,ast.Assign) and any(isinstance(x,ast.Name) and x.id in aliases for x in node.targets):body.append(node)
    module=types.ModuleType('contracts_'+file.replace('.','_'))
    module.__dict__.update(BaseModel=BaseModel,Field=Field,StrictInt=StrictInt,Literal=Literal,date=date,Decimal=Decimal,
                           watch=types.SimpleNamespace(SELECTOR_MAX=200))
    sys.modules[module.__name__]=module
    exec(compile(ast.fix_missing_locations(ast.Module(body=body,type_ignores=[])),str(backend/'routers'/file),'exec'),module.__dict__)
    return module

reminders=classes('reminders.py',{'ReminderIn','ReminderPatch','DoneIn','StopIn'},('Kind','CycleUnit'))
plans=classes('mortgage.py',{'PlanIn','PlanUpdate'})
stock=classes('stock.py',{'FavoriteIn'})
proxy=classes('proxyswitch.py',{'SwitchIn'})
clip=classes('clip.py',{'SettingsIn'})
reader=classes('../weidu/schemas.py',{'FeedCreate','FeedUpdate','StatePatch','BulkState','DiscoverIn','CheckIn','PrefsPatch','ImportFeed','ImportIn'})
watch=classes('watch.py',{'PreviewIn','WatchCreate','WatchUpdate'})
digest=classes('digest.py',{'SettingsIn','RunIn','GrantIn'})
saved=classes('readlater.py',{'SaveIn'})

examples=[
 ('asset create',schemas.AssetCreate,dict(name='fixture',purchase_price='8799.00',quantity='1',purchase_date='2020-01-01',category_id=None,valuation_method='manual',current_value=None,expected_life_days=None,target_daily_cost=None,salvage_rate=None,tags=['数码'],note='')),
 ('asset edit',schemas.AssetUpdate,dict(name='fixture',category_id='1',purchase_price='8799.00',purchase_date='2020-01-01',quantity='1',tags=[])),
 ('sell',schemas.SellIn,dict(sold_price='100.00',sold_date='2026-01-01',sold_channel='fixture',note='')),
 ('cost',schemas.CostIn,dict(occurred_on='2026-01-01',kind='subscription',amount='12.34',note='')),
 ('income',schemas.IncomeIn,dict(occurred_on='2026-01-01',kind='cashback',amount='1.00',note='')),
 ('valuation',schemas.ValuationIn,dict(as_of='2026-01-01',value='100.00',source='manual',note='')),
 ('wish',schemas.WishCreate,dict(name='fixture',target_amount='100.00',target_date=None,note='')),
 ('deposit',schemas.WishDepositIn,dict(occurred_on='2026-01-01',amount='10.00',note='')),
 ('reminder create',reminders.ReminderIn,dict(kind='renewal',title='',due_on='2026-12-01',cycle_unit='month',cycle_n='1',amount=None,lead_days='7')),
 ('reminder edit clear amount',reminders.ReminderPatch,dict(title='',due_on='2026-12-01',cycle_unit='month',cycle_n='1',amount=None,clear_amount=True,active=True,lead_days='7')),
 ('reminder complete',reminders.DoneIn,dict(due_on='2026-12-01',occurred_on='2026-11-02',amount=None,note='')),
 ('plan create',plans.PlanIn,dict(kind='new',name='fixture',data={'v':1,'type':'commercial','amount':100})),
 ('plan update CAS',plans.PlanUpdate,dict(name='fixture',data={'v':1},base='2026-11-02T00:00:00+00:00')),
 ('favorite',stock.FavoriteIn,dict(q='600000')),
 ('layout',schemas.HomeLayoutIn,dict(order=['clip','weidu'],hidden=['clip'])),
 ('password',schemas.PasswordChangeIn,dict(old_password='fixture-old',new_password='fixture-new')),
 ('invite',schemas.InviteIn,dict(note='fixture',days='7',max_uses='1')),
 ('access',schemas.AppAccessIn,dict(apps={'stock':True})),
 ('disable',schemas.DisableIn,dict(disabled=True)),
 ('proxy strict integer',proxy.SwitchIn,dict(hours=1)),
 ('bark keep key',clip.SettingsIn,dict(bark_server='default')),
 ('bark clear key',clip.SettingsIn,dict(bark_server='official',bark_key='')),
 ('cloud subscribe',reader.FeedCreate,dict(url='https://fixture.invalid/rss',title='',group='',fetch_now=True)),
 ('cloud feed settings',reader.FeedUpdate,dict(title='Fixture',group='',sort='0',interval_minutes='60',auto_fulltext=True)),
 ('cloud opened state',reader.StatePatch,dict(opened=True,read=True)),
 ('cloud bulk state',reader.BulkState,dict(ids=[42,43],read=True)),
 ('cloud reader preferences',reader.PrefsPatch,dict(font='serif',font_size='md',density='comfortable',list_view='unread',keep_days=30,refresh_minutes=60,mark_read_on_open=True,auto_read_on_scroll=False,images_in_list=True)),
 ('cloud OPML import',reader.ImportIn,dict(feeds=[dict(url='https://fixture.invalid/rss',title='Fixture')],fetch_now=True)),
 ('watch preview',watch.PreviewIn,dict(url='https://fixture.invalid/page',selector='main a')),
 ('watch create',watch.WatchCreate,dict(url='https://fixture.invalid/page',selector='',interval_minutes='360',title='Watch',push=False)),
 ('watch update',watch.WatchUpdate,dict(selector='main a',interval_minutes='60',title='Watch',push=True)),
 ('digest settings',digest.SettingsIn,dict(enabled=True,push=False,push_time='08:30',count='5',llm=True)),
 ('digest explicit generate',digest.RunIn,dict(push=False)),
 ('digest grant',digest.GrantIn,dict(granted=True)),
 ('readlater save',saved.SaveIn,dict(url='https://fixture.invalid/article',title='Fixture')),
 ('stop reminder and retire asset',reminders.StopIn,dict(retire_asset=True)),
]
for name,model,payload in examples:
    parsed=model.model_validate(payload)
    if name=='asset create':assert parsed.purchase_price==Decimal('8799.00')
rejects=[(schemas.AssetCreate,dict(name='',purchase_price=-1,purchase_date='2020-01-01')),
         (schemas.WishCreate,dict(name='fixture',target_amount=0)),
         (reminders.ReminderIn,dict(kind='renewal',due_on='2026-12-01',cycle_n=0)),
         (proxy.SwitchIn,dict(hours='1')),
         (plans.PlanIn,dict(kind='other',name='fixture',data={})),
         (reader.FeedUpdate,dict(interval_minutes=0)),
         (reader.BulkState,dict(ids=list(range(5001)),read=True)),
         (watch.PreviewIn,dict(url='https://fixture.invalid',selector='x'*201)),
         (digest.SettingsIn,dict(push_time='12:00')),
         (digest.SettingsIn,dict(count=9))]
for model,payload in rejects:
    try:model.model_validate(payload)
    except ValidationError:pass
    else:raise AssertionError(f'{model.__name__} accepted invalid fixture')
print(f'{len(examples)} request examples validated against local schemas; {len(rejects)} invalid fixtures rejected.')
print('No server writes; native payload construction and UI still require runtime verification.')
