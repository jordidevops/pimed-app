/**
 * Portal HTML signature slots. Mirrors supabase/functions/_shared/signing-field-map.ts
 * HTML branch (width/height from the tag; defaults 180×60). Do not edit that file.
 */

export function injectIssuedHtmlSignatureMarkers(html: string): string {
  const tagRe = /<signature-field\b([^>]*)\s*\/?>(?:<\/signature-field>)?/gi
  return html.replace(tagRe, (_match, attrs: string) => {
    const role = attrs.match(/role=["']([^"']+)["']/i)?.[1]?.trim() ?? 'signer'
    const name = attrs.match(/name=["']([^"']+)["']/i)?.[1]?.trim() ?? role
    const wMatch = attrs.match(/width:\s*(\d+)px/i)
    const hMatch = attrs.match(/height:\s*(\d+)px/i)
    const widthPx = wMatch ? parseInt(wMatch[1], 10) : 180
    const heightPx = hMatch ? parseInt(hMatch[1], 10) : 60
    return (
      `<div class="sig-slot" data-sig-role="${role}" ` +
      `style="display:block;width:${widthPx}px;height:${heightPx}px;` +
      `border:1px dashed #999;position:relative;box-sizing:border-box;margin:10px 0;">` +
      `<span style="position:absolute;left:6px;top:6px;font-size:10pt;color:#555;">${name}</span>` +
      `<span style="position:absolute;left:6px;bottom:6px;font-size:9pt;color:#888;font-family:monospace;">` +
      `[FIRMA:${role}]</span>` +
      `</div>`
    )
  })
}
