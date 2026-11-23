# Nochevieja 2026

Web para organizar la fiesta: la gente se apunta, cada uno tiene su ficha, cada recaudador su lista de cobros y los gestores lo controlan todo con un PIN.

- `index.html`: la web.
  - Inicio: info, apuntarse (teléfono + PIN de 4 cifras) y «Ya estoy apuntado».
  - `?t=<token>`: ficha personal (lo que toca pagar, a quién, concepto, aviso «ya he pagado», calendario, acompañantes, grupo de WhatsApp).
  - `?r=<token>`: enlace de cobros de un recaudador (confirmar pagos, recordatorios por WhatsApp).
  - `#gestion`: gestión con PIN (gente, recaudadores, compra y gastos, datos de la fiesta).
- `config.js`: URL de Supabase y clave publishable.
- `schema.sql`: base de datos. Se pega en Supabase → SQL Editor → Run. Se puede volver a ejecutar sin perder datos.

## Reglas
- Teléfono obligatorio y único (da igual +34, espacios o guiones). Los gestores pueden apuntar a alguien sin teléfono.
- Recaudador por sorteo equitativo (el activo con menos gente; empate al azar).
- «Ya he pagado» solo avisa; el pago lo confirma el recaudador desde su enlace o un gestor.
- Aforo: solo cuentan los «sí». Lleno → lista de espera; pasan solos al liberarse plazas.
- Fechas límite de inscripción y de pago (hora de Madrid).

## Seguridad
Tablas cerradas con RLS; la web solo llama a funciones. PIN de gestor: 8 fallos → 15 min de bloqueo. PIN personal: 5 fallos → 15 min; 15 fallos → bloqueado hasta crear uno nuevo desde el enlace.
Supabase gratis pausa el proyecto tras una semana sin uso; se reactiva desde su panel.
