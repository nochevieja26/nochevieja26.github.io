-- Nochevieja 2026 · base de datos para Supabase
-- Pega TODO este archivo en Supabase → SQL Editor → New query → Run.
-- Se puede volver a ejecutar cuando cambie: no borra datos ya guardados.
--
-- Seguridad: las tablas están cerradas (RLS sin políticas). La web solo usa
-- las funciones de abajo:
--   · públicas: ver la info de la fiesta, apuntarse, entrar con teléfono + PIN
--   · con enlace personal (token): ver y editar la propia ficha
--   · con enlace de recaudador: ver y confirmar los cobros propios
--   · con PIN de gestor: todo lo demás

create extension if not exists pgcrypto with schema extensions;

-- ======================= TABLAS =======================
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  event_name text not null default 'Nochevieja 2026',
  place text not null default '',
  addr text not null default '',
  start_time text not null default '22:00',
  end_time text not null default '',
  pay_to text not null default '',
  pay_how text not null default '',
  notes text not null default '',
  people_override int,            -- null = repartir entre los confirmados
  admin_pin_hash text,            -- null = PIN aún sin crear
  fail_count int not null default 0,
  fail_since timestamptz
);
insert into public.settings (id, people_override, notes)
values (1, 35, 'El alcohol lo trae cada uno.')
on conflict (id) do nothing;
alter table public.settings add column if not exists whatsapp_url text not null default '';
alter table public.settings add column if not exists admin_contact text not null default '';
alter table public.settings add column if not exists capacity int;            -- aforo (solo cuentan los "sí"); null = sin límite
alter table public.settings add column if not exists signup_deadline date;    -- último día para apuntarse (incluido)
alter table public.settings add column if not exists pay_deadline date;       -- último día para pagar
alter table public.settings add column if not exists faq jsonb not null default '[]';  -- preguntas frecuentes [{q,a}]
alter table public.settings add column if not exists tickets_enabled boolean not null default false;  -- botón «Descargar mi entrada (PDF)»
alter table public.settings add column if not exists price_hint text not null default '';  -- precio orientativo que se enseña en el inicio (vacío = el calculado)
update public.settings set faq = '[
 {"q":"¿Qué tengo que traer?","a":"Solo tu bebida. El local, el hielo, los vasos, las chuches y la música los pagamos entre todos."},
 {"q":"¿Puedo llevar a alguien?","a":"Sí. Apúntale desde tu entrada, en «Vengo con alguien». Tendrá su propia entrada y pagará su parte."},
 {"q":"¿Cuánto tengo que pagar y a quién?","a":"Lo ves en tu entrada: el importe y a quién hacer el Bizum. Puede bajar un poco si se apunta más gente."},
 {"q":"¿Y si al final no puedo ir?","a":"Entra en tu entrada y marca «No voy» cuanto antes para dejar sitio. Si ya habías pagado, habla con tu recaudador."},
 {"q":"¿Puedo pagar en efectivo?","a":"Sí, aunque mejor por Bizum: es más fácil llevar las cuentas. Si pagas en efectivo, dáselo en mano a tu recaudador antes de la fiesta."},
 {"q":"He olvidado mi PIN","a":"Pide tu enlace a un gestor. Desde tu entrada puedes crear un PIN nuevo."}
]'::jsonb where id = 1 and faq = '[]'::jsonb;
-- Grupo de WhatsApp de la fiesta (solo si aún no se ha puesto otro desde la gestión)
update public.settings set whatsapp_url = 'https://chat.whatsapp.com/GUb7L7ib0mGElP6Ic2JWpd' where id = 1 and whatsapp_url = '';

-- Recaudadores: a cada persona se le asigna uno por sorteo equitativo
create table if not exists public.collectors (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  phone text not null default '' check (char_length(phone) <= 30),   -- número de Bizum
  active boolean not null default true,                               -- false = no recibe gente nueva
  created_at timestamptz not null default now()
);
alter table public.collectors add column if not exists token uuid not null default gen_random_uuid();  -- enlace de cobros
do $$ begin
  alter table public.collectors add constraint collectors_token_key unique (token);
exception when duplicate_table or duplicate_object then null; end $$;

create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  phone text not null default '' check (char_length(phone) <= 30),
  status text not null default 'si',
  brings text not null default '' check (char_length(brings) <= 120),
  paid boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.guests drop constraint if exists guests_status_check;
alter table public.guests add constraint guests_status_check check (status in ('si','quiza','no','espera'));
alter table public.guests add column if not exists pay_method text not null default 'bizum';
alter table public.guests add column if not exists collector_id uuid references public.collectors(id) on delete set null;
do $$ begin
  alter table public.guests add constraint guests_pay_method_chk check (pay_method in ('bizum','efectivo'));
exception when duplicate_object then null; end $$;
-- Teléfono normalizado (solo cifras, sin prefijo +34) para no apuntar dos veces a la misma persona
alter table public.guests add column if not exists phone_key text generated always as (
  case when regexp_replace(phone,'\D','','g') ~ '^(0034|34)[0-9]{9}$' then right(regexp_replace(phone,'\D','','g'),9)
       else regexp_replace(phone,'\D','','g') end) stored;
do $$ begin
  create unique index if not exists guests_phone_key_uq on public.guests (phone_key) where phone_key <> '';
exception when unique_violation then
  raise notice 'Hay teléfonos repetidos en la lista: arréglalos en la gestión y vuelve a ejecutar este script.';
end $$;
-- PIN personal de 4 cifras para volver a entrar con teléfono + PIN
alter table public.guests add column if not exists pin_hash text;
alter table public.guests add column if not exists login_fails int not null default 0;
alter table public.guests add column if not exists login_fail_since timestamptz;
alter table public.guests add column if not exists login_fails_total int not null default 0;  -- 15 → bloqueado hasta crear PIN nuevo
-- Aviso "ya he pagado" (no marca como pagado: lo confirma el recaudador)
alter table public.guests add column if not exists paid_claim_at timestamptz;
-- Acompañante: quién le apuntó
alter table public.guests add column if not exists invited_by uuid references public.guests(id) on delete set null;
-- PIN inicial de un acompañante: lo ve quien le apuntó hasta que el acompañante lo cambie
alter table public.guests add column if not exists pin_initial text;
-- Código corto para el enlace de invitación (?de=CODIGO); no es el enlace privado
alter table public.guests add column if not exists ref_code text not null default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
do $$ begin
  alter table public.guests add constraint guests_ref_code_key unique (ref_code);
exception when duplicate_table or duplicate_object then null; end $$;

create table if not exists public.items (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  cat text not null default 'Otros',
  q numeric not null default 1 check (q >= 0),
  p numeric not null default 0 check (p >= 0),
  who text not null default '',
  done boolean not null default false,
  opt boolean not null default false,   -- true = "si sobra dinero", no cuenta
  ord int not null default 0
);
alter table public.items add column if not exists spent numeric check (spent >= 0);  -- lo gastado de verdad
insert into public.items (name, cat, q, p, ord, opt)
select * from (values
  ('Alquiler del local','Local',1,500,1,false),
  ('Vasos de cubata (pack de 100)','Bebida',2,6,2,false),
  ('Hielo (bolsa de 2 kg)','Bebida',15,1.5,3,false),
  ('Chuches surtidas (bolsa de 1 kg)','Picoteo',4,7,4,false),
  ('Alquiler de altavoces','Música',1,90,5,false),
  ('Refresco para mezclar (botella de 2 L)','Bebida',35,1,6,true)
) v(name,cat,q,p,ord,opt)
where not exists (select 1 from public.items);

alter table public.settings   enable row level security;
alter table public.collectors enable row level security;
alter table public.guests     enable row level security;
alter table public.items      enable row level security;
revoke all on public.settings, public.collectors, public.guests, public.items from anon, authenticated;

-- Versiones antiguas de funciones cuyos parámetros han cambiado
drop function if exists public._check_pin(text);
drop function if exists public.signup(text,text,text,text);
drop function if exists public.signup(text,text,text,text,text,text);
drop function if exists public.signup(text,text,text,text,text);
drop function if exists public.update_me(uuid,text,text,text,text);
drop function if exists public.update_me(uuid,text,text,text,text,text);
drop function if exists public.admin_guest_save(text,uuid,text,text,text,text,boolean);
drop function if exists public.admin_guest_save(text,uuid,text,text,text,text,boolean,text,uuid);
drop function if exists public.admin_item_save(text,uuid,text,text,numeric,numeric,text,boolean,boolean);

-- ======================= AYUDAS =======================
create or replace function public._phone_key(p text)
returns text language sql immutable as $$
  select case when regexp_replace(coalesce(p,''),'\D','','g') ~ '^(0034|34)[0-9]{9}$' then right(regexp_replace(p,'\D','','g'),9)
              else regexp_replace(coalesce(p,''),'\D','','g') end;
$$;

-- Nombre de quien ya tiene ese teléfono (o null). p_except: no contar a esta persona
create or replace function public._phone_owner(p_phone text, p_except uuid)
returns text language sql stable security definer set search_path = public as $$
  select name from guests
  where public._phone_key(p_phone) <> '' and phone_key = public._phone_key(p_phone)
    and id is distinct from p_except
  limit 1;
$$;

create or replace function public._today()
returns date language sql stable as $$ select (now() at time zone 'Europe/Madrid')::date $$;

create or replace function public._signups_open()
returns boolean language sql stable security definer set search_path = public as $$
  select signup_deadline is null or public._today() <= signup_deadline from settings where id = 1;
$$;

-- ¿Queda sitio para un "sí" más? (p_except: no contar a esta persona)
create or replace function public._has_room(p_except uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select s.capacity is null
      or (select count(*) from guests where status = 'si' and id is distinct from p_except) < s.capacity
  from settings s where s.id = 1;
$$;

create or replace function public._money()
returns json language sql stable security definer set search_path = public as $$
  with t as (
    select coalesce(sum(q*p) filter (where not opt),0) total,
           coalesce(sum(q*p) filter (where not opt and not done),0) pending,
           coalesce(sum(q*p) filter (where opt),0) extra
    from items),
  g as (
    select count(*) filter (where status='si') si,
           count(*) filter (where status='quiza') quiza,
           count(*) filter (where status='espera') espera,
           count(*) filter (where status='si' and paid) paid
    from guests),
  d as (
    select greatest(1, coalesce(s.people_override, g.si)) n, s.people_override, s.capacity
    from settings s, g where s.id = 1)
  select json_build_object(
    'total', t.total, 'pending', t.pending, 'extra', t.extra,
    'people', d.n, 'by_confirmed', d.people_override is null,
    'per_person', ceil(t.total / d.n * 100) / 100,
    'extra_per_person', ceil(t.extra / d.n * 100) / 100,
    'si', g.si, 'quiza', g.quiza, 'espera', g.espera, 'paid', g.paid,
    'capacity', d.capacity, 'spots_left', case when d.capacity is null then null else greatest(d.capacity - g.si, 0) end,
    'collected', round(g.paid * ceil(t.total / d.n * 100) / 100, 2))
  from t, g, d;
$$;

create or replace function public._event()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('event_name',event_name,'place',place,'addr',addr,
    'start_time',start_time,'end_time',end_time,'pay_how',pay_how,
    'notes',notes,'people_override',people_override,'has_pin',admin_pin_hash is not null,
    'admin_contact',admin_contact,'capacity',capacity,
    'signup_deadline',signup_deadline,'pay_deadline',pay_deadline,'signups_open',public._signups_open(),
    'collectors',(select count(*) from collectors where active),'faq',faq,'price_hint',price_hint,'tickets_enabled',tickets_enabled)
  from settings where id = 1;
$$;

-- Sorteo equitativo: el recaudador activo con menos gente asignada; si hay empate, al azar.
create or replace function public._pick_collector()
returns uuid language sql volatile security definer set search_path = public as $$
  select c.id from collectors c
  left join guests g on g.collector_id = c.id and g.status in ('si','quiza')
  where c.active
  group by c.id
  order by count(g.id), random()
  limit 1;
$$;

-- Pasa a "sí" a los primeros de la lista de espera mientras haya sitio,
-- y asigna recaudador a quien no tenga (o lo tenga desactivado y aún no haya pagado)
create or replace function public._assign_missing()
returns int language plpgsql volatile security definer set search_path = public as $$
declare r record; n int := 0;
begin
  perform pg_advisory_xact_lock(2026);
  loop
    exit when not public._has_room(null);
    update guests set status = 'si'
    where id = (select id from guests where status = 'espera' order by created_at limit 1);
    exit when not found;
  end loop;
  for r in
    select g.id from guests g left join collectors c on c.id = g.collector_id
    where g.status in ('si','quiza') and (g.collector_id is null or (not c.active and not g.paid))
    order by g.created_at
  loop
    update guests set collector_id = public._pick_collector() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public._collector_json(p_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('name',name,'phone',phone) from collectors where id = p_id;
$$;

-- Alta común (apuntarse y acompañantes). Devuelve el token nuevo.
create or replace function public._new_guest(p_name text, p_phone text, p_status text, p_pay text, p_pin text, p_invited_by uuid)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare t uuid; st text := case when p_status in ('si','quiza','no') then p_status else 'si' end;
begin
  if char_length(trim(coalesce(p_name,''))) = 0 then raise exception 'Falta el nombre'; end if;
  if char_length(public._phone_key(p_phone)) < 9 then
    raise exception 'Pon un teléfono válido. Si no quiere darlo, que hable con un gestor.';
  end if;
  if p_pin is not null and p_pin !~ '^[0-9]{4}$' then raise exception 'El PIN tiene que ser de 4 cifras'; end if;
  if not public._signups_open() then raise exception 'Las inscripciones están cerradas. Habla con un gestor.'; end if;
  if (select count(*) from guests) >= 300 then raise exception 'La lista está llena'; end if;
  perform pg_advisory_xact_lock(2026);
  if public._phone_owner(p_phone, null) is not null then
    raise exception 'Ese teléfono ya está apuntado. Si es el tuyo, entra en «Ya estoy apuntado» con tu teléfono y tu PIN.';
  end if;
  if st = 'si' and not public._has_room(null) then st := 'espera'; end if;
  insert into guests (name, phone, status, pay_method, collector_id, pin_hash, invited_by)
  values (left(trim(p_name),60), left(trim(coalesce(p_phone,'')),30), st,
          case when p_pay = 'efectivo' then 'efectivo' else 'bizum' end,
          case when st in ('si','quiza') then public._pick_collector() end,
          case when p_pin is not null then crypt(p_pin, gen_salt('bf', 6)) end,
          p_invited_by)
  returning token into t;
  return t;
end $$;

-- ======================= PÚBLICO =======================
-- Solo lo que pone cada uno; ni total, ni lista de gastos, ni nombres (eso lo ven los gestores)
create or replace function public.public_info()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'event', public._event(),
    'money', (select json_build_object('per_person', m->'per_person', 'si', m->'si', 'quiza', m->'quiza', 'espera', m->'espera', 'capacity', m->'capacity', 'spots_left', m->'spots_left') from (select public._money()::jsonb m) x),
    'coming', '[]'::json);  -- los nombres de quién viene ya no se enseñan en público
$$;

-- p_ref: código de quien invita (enlace ?de=CODIGO o «apuntar a otra persona» desde su móvil)
create or replace function public.signup(p_name text, p_phone text, p_status text, p_pay text, p_pin text, p_ref text)
returns uuid language plpgsql volatile security definer set search_path = public as $$
begin
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'El PIN tiene que ser de 4 cifras'; end if;
  return public._new_guest(p_name, p_phone, p_status, p_pay, p_pin,
    (select id from guests where ref_code = upper(trim(coalesce(p_ref,''))) limit 1));
end $$;

-- Nombre de quien invita, para saludar en la página («Te invita Laura»)
create or replace function public.ref_name(p_ref text)
returns text language sql stable security definer set search_path = public as $$
  select split_part(name,' ',1) from guests where ref_code = upper(trim(coalesce(p_ref,''))) and status <> 'no' limit 1;
$$;

-- Entrar con teléfono + PIN. Devuelve {"token": ...} o {"error": ...}
-- (no lanza error para que el contador de fallos se guarde)
create or replace function public.login(p_phone text, p_pin text)
returns json language plpgsql volatile security definer set search_path = public, extensions as $$
declare g guests; bad constant text := 'Teléfono o PIN incorrectos';
begin
  if char_length(public._phone_key(p_phone)) < 9 or coalesce(p_pin,'') !~ '^[0-9]{4}$' then
    return json_build_object('error', bad);
  end if;
  select * into g from guests where phone_key = public._phone_key(p_phone) for update;
  if g.id is null then return json_build_object('error', bad); end if;
  if g.pin_hash is null then
    return json_build_object('error','Todavía no tienes PIN. Pide tu enlace a un gestor (o a quien te apuntó) y créalo desde tu ficha.');
  end if;
  if g.login_fails_total >= 15 then
    return json_build_object('error','Acceso bloqueado por demasiados intentos. Pide tu enlace a un gestor y crea un PIN nuevo.');
  end if;
  if g.login_fails >= 5 and g.login_fail_since > now() - interval '15 minutes' then
    return json_build_object('error','Demasiados intentos. Espera 15 minutos.');
  end if;
  if crypt(p_pin, g.pin_hash) <> g.pin_hash then
    update guests set
      login_fails = case when login_fail_since > now() - interval '15 minutes' then login_fails + 1 else 1 end,
      login_fail_since = case when login_fail_since > now() - interval '15 minutes' then login_fail_since else now() end,
      login_fails_total = login_fails_total + 1
    where id = g.id;
    return json_build_object('error', bad);
  end if;
  update guests set login_fails = 0, login_fail_since = null where id = g.id and login_fails > 0;
  return json_build_object('token', g.token);
end $$;

-- ======================= FICHA PERSONAL =======================
create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'guest', json_build_object('name',g.name,'phone',g.phone,'status',g.status,'paid',g.paid,'pay_method',g.pay_method,
                               'has_pin',g.pin_hash is not null,'claimed',g.paid_claim_at is not null,
                               'wait_pos', case when g.status = 'espera' then
                                  (select count(*) from guests w where w.status = 'espera' and w.created_at <= g.created_at) end),
    'collector', public._collector_json(g.collector_id),
    'invited_by', (select name from guests i where i.id = g.invited_by),
    'ref_code', g.ref_code,
    'brought', (select count(*) from guests b where b.invited_by = g.id and b.status <> 'no'),
    'companions', coalesce((select json_agg(json_build_object('name',c.name,'phone',c.phone,'status',c.status,'paid',c.paid,
                                    'token',c.token,'has_pin',c.pin_hash is not null,'pin',c.pin_initial) order by c.created_at)
                            from guests c where c.invited_by = g.id), '[]'::json),
    'whatsapp_url', (select whatsapp_url from settings where id = 1),
    'event', public._event(),
    'money', (select json_build_object('per_person', m->'per_person') from (select public._money()::jsonb m) x))
  from guests g where g.token = p_token;
$$;

create or replace function public.update_me(p_token uuid, p_name text, p_phone text, p_status text, p_pay text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare g guests; st text;
begin
  select * into g from guests where token = p_token;
  if g.id is null then raise exception 'Enlace no válido'; end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then raise exception 'Falta el nombre'; end if;
  if char_length(public._phone_key(p_phone)) < 9 then
    raise exception 'Pon un teléfono válido. Si no quieres darlo, habla con un gestor.';
  end if;
  if public._phone_owner(p_phone, g.id) is not null then
    raise exception 'Ese teléfono ya lo tiene otra persona de la lista. Habla con un gestor.';
  end if;
  perform pg_advisory_xact_lock(2026);
  st := case when p_status in ('si','quiza','no') then p_status else g.status end;
  if g.status = 'espera' and st <> 'no' then st := 'espera';               -- sigue en la cola
  elsif st = 'si' and g.status <> 'si' and not public._has_room(g.id) then st := 'espera';
  end if;
  update guests set name = left(trim(p_name),60), phone = left(trim(coalesce(p_phone,'')),30), status = st,
    pay_method = case when p_pay in ('bizum','efectivo') then p_pay else pay_method end
  where id = g.id;
  perform public._assign_missing();
end $$;

-- Crear o cambiar el PIN desde la ficha. Desbloquea el acceso.
create or replace function public.set_pin(p_token uuid, p_pin text)
returns json language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then return json_build_object('error','El PIN tiene que ser de 4 cifras'); end if;
  update guests set pin_hash = crypt(p_pin, gen_salt('bf', 6)), pin_initial = null, login_fails = 0, login_fail_since = null, login_fails_total = 0
  where token = p_token;
  if not found then return json_build_object('error','Enlace no válido'); end if;
  return json_build_object('ok', true);
end $$;

-- Aviso "ya he pagado" (p_on = false lo retira). No marca como pagado.
create or replace function public.claim_paid(p_token uuid, p_on boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
begin
  update guests set paid_claim_at = case when p_on then now() end where token = p_token and not paid;
  return json_build_object('ok', true);
end $$;

-- Apuntar a un acompañante (máximo 3 por persona). Devuelve el token del acompañante.
create or replace function public.add_companion(p_token uuid, p_name text, p_phone text)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare g guests; pin text; t uuid;
begin
  select * into g from guests where token = p_token;
  if g.id is null then raise exception 'Enlace no válido'; end if;
  if (select count(*) from guests where invited_by = g.id) >= 3 then raise exception 'Máximo 3 acompañantes por persona'; end if;
  pin := lpad(floor(random() * 10000)::int::text, 4, '0');
  t := public._new_guest(p_name, p_phone, 'si', 'bizum', pin, g.id);
  update guests set pin_initial = pin where token = t;
  return t;
end $$;

-- ======================= RECAUDADOR (enlace de cobros) =======================
create or replace function public.collector_view(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare c collectors;
begin
  select * into c from collectors where token = p_token;
  if c.id is null then return null; end if;
  return json_build_object(
    'collector', json_build_object('name',c.name,'phone',c.phone,'active',c.active),
    'event', public._event(), 'money', public._money(),
    'people', coalesce((select json_agg(json_build_object('id',id,'name',name,'phone',phone,'status',status,'pay_method',pay_method,
                                         'paid',paid,'claimed_at',paid_claim_at) order by paid, paid_claim_at is null, name)
                        from guests where collector_id = c.id and status in ('si','quiza')), '[]'::json));
end $$;

create or replace function public.collector_mark(p_token uuid, p_guest uuid, p_paid boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare cid uuid := (select id from collectors where token = p_token);
begin
  if cid is null then return json_build_object('error','Enlace de recaudador no válido'); end if;
  update guests set paid = coalesce(p_paid,false),
                    paid_claim_at = case when coalesce(p_paid,false) then paid_claim_at else null end
  where id = p_guest and collector_id = cid;
  if not found then return json_build_object('error','Esa persona no es de tu lista'); end if;
  return json_build_object('ok', true);
end $$;

-- ======================= GESTORES (PIN) =======================
-- Las funciones de gestión no lanzan error con un PIN incorrecto: devuelven
-- {"error": "..."} para que el contador de intentos fallidos se guarde.
create or replace function public._pin_error(p_pin text)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare s settings;
begin
  select * into s from settings where id = 1 for update;
  if s.admin_pin_hash is null then return 'Todavía no hay PIN de gestor'; end if;
  if s.fail_count >= 8 and s.fail_since > now() - interval '15 minutes' then
    return 'Demasiados intentos. Espera 15 minutos.';
  end if;
  if crypt(coalesce(p_pin,''), s.admin_pin_hash) <> s.admin_pin_hash then
    update settings set fail_count = case when fail_since > now() - interval '15 minutes' then fail_count + 1 else 1 end,
                        fail_since = case when fail_since > now() - interval '15 minutes' then fail_since else now() end
    where id = 1;
    return 'PIN incorrecto';
  end if;
  update settings set fail_count = 0, fail_since = null where id = 1 and fail_count > 0;
  return null;
end $$;

create or replace function public.admin_setup_pin(p_new text)
returns json language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  if char_length(coalesce(p_new,'')) < 6 then return json_build_object('error','El PIN debe tener al menos 6 caracteres'); end if;
  update settings set admin_pin_hash = crypt(p_new, gen_salt('bf', 8)) where id = 1 and admin_pin_hash is null;
  if not found then return json_build_object('error','El PIN ya está creado'); end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_change_pin(p_pin text, p_new text)
returns json language plpgsql volatile security definer set search_path = public, extensions as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(coalesce(p_new,'')) < 6 then return json_build_object('error','El PIN debe tener al menos 6 caracteres'); end if;
  update settings set admin_pin_hash = crypt(p_new, gen_salt('bf', 8)) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_state(p_pin text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); pp numeric; v_spent numeric;
begin
  if e is not null then return json_build_object('error', e); end if;
  pp := (public._money()->>'per_person')::numeric;
  v_spent := coalesce((select sum(i.spent) from items i), 0);
  return json_build_object(
    'event', public._event(), 'money', public._money(), 'spent', v_spent,
    'whatsapp_url', (select whatsapp_url from settings where id = 1),
    'collectors', coalesce((select json_agg(x order by x.created_at) from (
       select c.id, c.name, c.phone, c.active, c.created_at, c.token,
              count(g.id) filter (where g.status in ('si','quiza')) assigned,
              count(g.id) filter (where g.status = 'si' and g.paid) paid,
              count(g.id) filter (where g.status = 'si' and not g.paid) unpaid,
              count(g.id) filter (where g.status = 'si' and not g.paid and g.paid_claim_at is not null) claimed,
              count(g.id) filter (where g.status in ('si','quiza') and g.pay_method = 'efectivo') cash,
              round(count(g.id) filter (where g.status = 'si' and g.paid) * pp, 2) collected
       from collectors c left join guests g on g.collector_id = c.id
       group by c.id) x), '[]'::json),
    'guests', coalesce((select json_agg(json_build_object('id',g.id,'token',g.token,'name',g.name,'phone',g.phone,'status',g.status,
        'paid',g.paid,'pay_method',g.pay_method,'collector_id',g.collector_id,'has_pin',g.pin_hash is not null,
        'locked',g.login_fails_total >= 15,'claimed',g.paid_claim_at is not null,
        'invited_by',(select i.name from guests i where i.id = g.invited_by),'invited_by_id',g.invited_by,
        'brought',(select count(*) from guests b where b.invited_by = g.id and b.status <> 'no'),'created_at',g.created_at) order by g.name) from guests g), '[]'::json),
    'items', coalesce((select json_agg(json_build_object('id',i.id,'name',i.name,'cat',i.cat,'q',i.q,'p',i.p,'who',i.who,'done',i.done,'opt',i.opt,'ord',i.ord,'spent',i.spent) order by i.ord, i.name) from items i), '[]'::json));
end $$;

create or replace function public.admin_guest_save(p_pin text, p_id uuid, p_name text, p_phone text, p_status text, p_brings text, p_paid boolean, p_pay text, p_collector uuid, p_invited_by uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); r uuid; dup text;
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then return json_build_object('error','Falta el nombre'); end if;
  dup := public._phone_owner(p_phone, p_id);
  if dup is not null then return json_build_object('error','Ese teléfono ya lo tiene ' || dup); end if;
  if p_id is null then
    insert into guests (name, phone, status, brings, paid, pay_method, collector_id, invited_by)
    values (left(trim(p_name),60), left(trim(coalesce(p_phone,'')),30),
            case when p_status in ('si','quiza','no','espera') then p_status else 'si' end,
            left(trim(coalesce(p_brings,'')),120), coalesce(p_paid,false),
            case when p_pay = 'efectivo' then 'efectivo' else 'bizum' end, p_collector, p_invited_by)
    returning id into r;
  else
    update guests set name = left(trim(p_name),60), phone = left(trim(coalesce(p_phone,'')),30),
      status = case when p_status in ('si','quiza','no','espera') then p_status else status end,
      brings = left(trim(coalesce(p_brings,brings)),120), paid = coalesce(p_paid, paid),
      pay_method = case when p_pay in ('bizum','efectivo') then p_pay else pay_method end,
      collector_id = p_collector,
      invited_by = case when p_invited_by = p_id then invited_by else p_invited_by end
    where id = p_id returning id into r;
  end if;
  perform public._assign_missing();
  return json_build_object('id', r);
end $$;

create or replace function public.admin_guest_delete(p_pin text, p_id uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  delete from guests where id = p_id;
  perform public._assign_missing();
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_collector_save(p_pin text, p_id uuid, p_name text, p_phone text, p_active boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); r uuid; n int;
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then return json_build_object('error','Falta el nombre'); end if;
  if p_id is null then
    if (select count(*) from collectors) >= 10 then return json_build_object('error','Máximo 10 recaudadores'); end if;
    insert into collectors (name, phone, active) values (left(trim(p_name),40), left(trim(coalesce(p_phone,'')),30), coalesce(p_active,true))
    returning id into r;
  else
    update collectors set name = left(trim(p_name),40), phone = left(trim(coalesce(p_phone,'')),30), active = coalesce(p_active, active)
    where id = p_id returning id into r;
  end if;
  n := public._assign_missing();
  return json_build_object('id', r, 'moved', n);
end $$;

-- Borrar un recaudador: solo si nadie le ha pagado todavía; su gente se reparte entre los demás
create or replace function public.admin_collector_delete(p_pin text, p_id uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); n int;
begin
  if e is not null then return json_build_object('error', e); end if;
  if exists (select 1 from guests where collector_id = p_id and paid) then
    return json_build_object('error','Ya le han pagado: desactívalo en vez de borrarlo, así no se pierden las cuentas');
  end if;
  update guests set collector_id = null where collector_id = p_id;
  delete from collectors where id = p_id;
  n := public._assign_missing();
  return json_build_object('ok', true, 'moved', n);
end $$;

-- Volver a sortear: reparte de forma equitativa a toda la gente que aún NO ha pagado
create or replace function public.admin_collectors_reshuffle(p_pin text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); n int;
begin
  if e is not null then return json_build_object('error', e); end if;
  if not exists (select 1 from collectors where active) then return json_build_object('error','No hay recaudadores activos'); end if;
  update guests set collector_id = null where not paid;
  n := public._assign_missing();
  return json_build_object('ok', true, 'moved', n);
end $$;

create or replace function public.admin_item_save(p_pin text, p_id uuid, p_name text, p_cat text, p_q numeric, p_p numeric, p_who text, p_done boolean, p_opt boolean, p_spent numeric)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); r uuid;
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then return json_build_object('error','Falta el nombre'); end if;
  if p_id is null then
    insert into items (name, cat, q, p, who, done, opt, spent, ord)
    values (left(trim(p_name),120), coalesce(nullif(p_cat,''),'Otros'), greatest(coalesce(p_q,0),0), greatest(coalesce(p_p,0),0),
            left(coalesce(p_who,''),40), coalesce(p_done,false), coalesce(p_opt,false), case when p_spent >= 0 then p_spent end,
            coalesce((select max(ord) from items),0) + 1)
    returning id into r;
  else
    update items set name = left(trim(p_name),120), cat = coalesce(nullif(p_cat,''),'Otros'),
      q = greatest(coalesce(p_q,0),0), p = greatest(coalesce(p_p,0),0), who = left(coalesce(p_who,''),40),
      done = coalesce(p_done,false), opt = coalesce(p_opt,false), spent = case when p_spent >= 0 then p_spent end
    where id = p_id returning id into r;
  end if;
  return json_build_object('id', r);
end $$;

create or replace function public.admin_item_delete(p_pin text, p_id uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  delete from items where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_settings_save(p_pin text, p jsonb)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  if coalesce(trim(p->>'whatsapp_url'),'') <> '' and split_part(trim(p->>'whatsapp_url'),'?',1) !~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]+$' then
    return json_build_object('error','El enlace del grupo debe ser una invitación de WhatsApp: https://chat.whatsapp.com/…');
  end if;
  update settings set
    event_name = left(coalesce(p->>'event_name', event_name),60),
    place      = left(coalesce(p->>'place', place),80),
    addr       = left(coalesce(p->>'addr', addr),160),
    start_time = left(coalesce(p->>'start_time', start_time),10),
    end_time   = left(coalesce(p->>'end_time', end_time),40),
    pay_how    = left(coalesce(p->>'pay_how', pay_how),200),
    notes      = left(coalesce(p->>'notes', notes),400),
    admin_contact = left(coalesce(p->>'admin_contact', admin_contact),120),
    price_hint = left(trim(coalesce(p->>'price_hint', price_hint)),40),
    tickets_enabled = case when p ? 'tickets_enabled' then coalesce((p->>'tickets_enabled')::boolean, false) else tickets_enabled end,
    whatsapp_url  = case when p ? 'whatsapp_url' then split_part(trim(p->>'whatsapp_url'),'?',1) else whatsapp_url end,
    people_override = case when p ? 'people_override' then nullif(p->>'people_override','')::int else people_override end,
    capacity        = case when p ? 'capacity' then nullif(p->>'capacity','')::int else capacity end,
    signup_deadline = case when p ? 'signup_deadline' then nullif(p->>'signup_deadline','')::date else signup_deadline end,
    pay_deadline    = case when p ? 'pay_deadline' then nullif(p->>'pay_deadline','')::date else pay_deadline end,
    faq = case when jsonb_typeof(p->'faq') = 'array' then coalesce((
            select jsonb_agg(jsonb_build_object('q', left(trim(x.it->>'q'),140), 'a', left(trim(coalesce(x.it->>'a','')),600)) order by x.n)
            from jsonb_array_elements(p->'faq') with ordinality x(it, n)
            where coalesce(trim(x.it->>'q'),'') <> '' and x.n <= 20), '[]'::jsonb)
          else faq end
  where id = 1;
  perform public._assign_missing();
  return json_build_object('ok', true);
end $$;

-- ======================= PERMISOS =======================
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.public_info(), public.signup(text,text,text,text,text,text), public.ref_name(text), public.login(text,text),
  public.me(uuid), public.update_me(uuid,text,text,text,text), public.set_pin(uuid,text),
  public.claim_paid(uuid,boolean), public.add_companion(uuid,text,text),
  public.collector_view(uuid), public.collector_mark(uuid,uuid,boolean),
  public.admin_setup_pin(text), public.admin_change_pin(text,text), public.admin_state(text),
  public.admin_guest_save(text,uuid,text,text,text,text,boolean,text,uuid,uuid), public.admin_guest_delete(text,uuid),
  public.admin_collector_save(text,uuid,text,text,boolean), public.admin_collector_delete(text,uuid),
  public.admin_collectors_reshuffle(text),
  public.admin_item_save(text,uuid,text,text,numeric,numeric,text,boolean,boolean,numeric), public.admin_item_delete(text,uuid),
  public.admin_settings_save(text,jsonb)
to anon, authenticated;
