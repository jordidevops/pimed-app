import { z } from 'zod'

export const loginSchema = z.object({
  email: z
    .string()
    .min(1, "El correu és obligatori")
    .email('Introdueix un correu vàlid'),
  password: z
    .string()
    .min(1, 'La contrasenya és obligatòria')
    .min(6, 'La contrasenya ha de tenir com a mínim 6 caràcters'),
})

export type LoginFormValues = z.infer<typeof loginSchema>
