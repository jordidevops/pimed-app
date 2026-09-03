import imageCompression from 'browser-image-compression'

export interface CompressOptions {
  maxSizeMB?: number
  maxWidthOrHeight?: number
}

/**
 * Comprimeix una imatge per a ser usada com a avatar.
 * Per defecte: 100 KB màxim, 400 px de costat major.
 */
export async function compressImage(
  file: File,
  options: CompressOptions = {},
): Promise<File> {
  const { maxSizeMB = 0.1, maxWidthOrHeight = 400 } = options

  return imageCompression(file, {
    maxSizeMB,
    maxWidthOrHeight,
    useWebWorker: true,
    fileType: file.type as 'image/jpeg' | 'image/png' | 'image/webp',
  })
}
