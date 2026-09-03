 **Contexto:** Estamos implementando el sistema de Supabase Auth en la app tenant-portal.

 **Objetivo:** Implementar el flujo completo de "Olvidé mi contraseña" y "Cambio de contraseña".

 **Requisitos técnicos:**
 1. Usa componentes de **Shadcn/ui** (`Card`, `Button`, `Input`, `Label`, `Toast/Sonner`).
 2. Implementa la lógica usando el cliente de `@supabase/supabase-js`.
 3. Los textos deben estar en catalán y seguir el patrón i18n de copilot-instructions.md.

 **Necesito que crees o completes según el sistema actual los 3 componentes/páginas:**

 1. **`ForgotPassword.tsx`**: 
    - Un formulario donde el usuario introduce su email.
    - Al enviar, usa `supabase.auth.resetPasswordForEmail`.
    - **Importante:** Tras el envío exitoso, oculta el input de email y muestra un input para el **código OTP de 6 dígitos** (usando `supabase.auth.verifyOtp` con `type: 'recovery'`). Esto permite al usuario validar su cuenta sin salir de la página si ya tiene el código.

 2. **`UpdatePassword.tsx`**: 
    - Esta página será el destino tanto del enlace del correo como de la validación exitosa del OTP.
    - Debe contener un formulario con: "Nueva contraseña" y "Confirmar contraseña".
    - Usa `supabase.auth.updateUser({ password: newPassword })`.

 3. **`ChangePasswordProfile.tsx`**:
    - Un componente sencillo para la sección de "Mi Perfil" (usuario ya logueado).
    - Permite cambiar la contraseña directamente sin correos electrónicos (debe pedir y comprovar la contyraseña anterior).

 **Instrucciones de diseño:**
 - Estilo minimalista y moderno con Tailwind acorde al estilo actual de la app.
 - Maneja estados de carga (`loading`) en los botones.
 - Maneja errores y éxitos con mensajes claros usando el componente Toast de Shadcn.
 - Asegúrate de que los tipos de TypeScript sean correctos.
 
Todo el sistema de login y recuperación de contraseñas debe ser coherente y seguro.
Ya tenemos partes implementadas con lo que los nombres de componentes y opciones son sugerencias. Tienes libertad de acción.