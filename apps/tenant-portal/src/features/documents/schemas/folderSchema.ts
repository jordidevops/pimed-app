import { z } from 'zod'

export const folderSchema = z.object({
  name: z.string().min(1, 'validation.folder_name_required').max(255),
})

export type FolderFormValues = z.infer<typeof folderSchema>
