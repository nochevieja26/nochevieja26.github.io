# Nochevieja 2026

Web para organizar la fiesta: la gente se apunta, cada uno tiene su ficha personal y los gestores lo controlan todo con un PIN.

- `index.html`: la web (inicio y apuntarse, ficha personal con `?t=<token>`, gestión en `#gestion`).
- `config.js`: URL de Supabase y clave publishable. Vacío = modo demostración.
- `schema.sql`: base de datos. Se pega en Supabase → SQL Editor → Run. Se puede volver a ejecutar sin perder datos.

## Puesta en marcha
1. Crear un proyecto en supabase.com y ejecutar `schema.sql` en el SQL Editor.
2. Poner en `config.js` la Project URL y la clave publishable/anon (nunca la secret/service_role).
3. Publicar en GitHub Pages: Settings → Pages → Deploy from a branch → `main` / root.
4. Entrar en `<url>#gestion` y crear el PIN de gestores (mínimo 6 caracteres).

## Seguridad
Las tablas están cerradas; la web solo llama a funciones:
- públicas: `public_info`, `signup`
- con el enlace personal: `me`, `update_me`
- con PIN: `admin_*` (8 fallos seguidos bloquean el PIN 15 minutos)

Pagos: cada persona recibe por sorteo equitativo uno de los recaudadores activos (el que menos gente tiene; empate al azar) y ve en su ficha su número de Bizum. También puede elegir efectivo (no recomendado).

Los teléfonos de los invitados solo los ven los gestores; el número de cada recaudador solo lo ve quien tiene que pagarle. En la parte pública solo aparecen los nombres de quien viene.

Supabase gratis pausa el proyecto tras una semana sin uso; se reactiva desde su panel.
