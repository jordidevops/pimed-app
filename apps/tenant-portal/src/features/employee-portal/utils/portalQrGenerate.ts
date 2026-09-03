import QRCode from 'qrcode'

export async function generatePortalQrDataUrl(
  text: string,
  size = 280,
): Promise<string> {
  return QRCode.toDataURL(text, {
    width: size,
    margin: 1,
    errorCorrectionLevel: 'M',
  })
}
