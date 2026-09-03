interface DriveSlotCardProps {
  index: number  // 0 = Internal, 1–3 = BYOS slots
  drive?: {
    id: string
    nickname: string | null
    provider_type: string
    bucket_name: string | null
    is_active: boolean
    is_locked: boolean
    is_verified: boolean
  } | null
}

const PROVIDER_LABELS: Record<string, string> = {
  supabase: 'Supabase (intern)',
  s3:       'Amazon S3',
  r2:       'Cloudflare R2',
  gcs:      'Google Cloud Storage',
  minio:    'MinIO',
}

export function DriveSlotCard({ index, drive }: DriveSlotCardProps) {
  const isInternal = index === 0

  if (isInternal) {
    return (
      <div className="rounded-xl border border-indigo-100 bg-indigo-50 p-4 space-y-1">
        <div className="flex items-center justify-between">
          <span className="text-xs font-semibold text-indigo-600 uppercase tracking-wide">
            Bucket intern
          </span>
          <span className="text-xs px-2 py-0.5 rounded-full bg-indigo-100 text-indigo-700 font-medium">
            Supabase
          </span>
        </div>
        <p className="text-sm text-gray-600">
          Emmagatzematge gestionat per la plataforma
        </p>
      </div>
    )
  }

  if (!drive) {
    return (
      <div className="rounded-xl border border-dashed border-gray-200 bg-gray-50 p-4 flex items-center gap-3">
        <span className="text-2xl">☁️</span>
        <div>
          <p className="text-sm font-medium text-gray-400">Slot BYOS #{index} lliure</p>
          <p className="text-xs text-gray-300">Sense drive configurat</p>
        </div>
      </div>
    )
  }

  const label = PROVIDER_LABELS[drive.provider_type] ?? drive.provider_type

  return (
    <div className="rounded-xl border border-gray-100 bg-white p-4 space-y-2 shadow-sm">
      <div className="flex items-center justify-between">
        <span className="text-xs font-semibold text-gray-400 uppercase tracking-wide">
          BYOS #{index}
        </span>
        <div className="flex gap-1.5">
          {drive.is_locked && (
            <span className="text-xs px-2 py-0.5 rounded-full bg-red-50 text-red-600 font-medium">
              Bloquejat
            </span>
          )}
          {!drive.is_active && (
            <span className="text-xs px-2 py-0.5 rounded-full bg-gray-100 text-gray-500 font-medium">
              Inactiu
            </span>
          )}
          {drive.is_active && !drive.is_locked && (
            <span className="text-xs px-2 py-0.5 rounded-full bg-green-50 text-green-700 font-medium">
              Actiu
            </span>
          )}
        </div>
      </div>
      <p className="text-sm font-medium text-gray-800">
        {drive.nickname ?? label}
      </p>
      <p className="text-xs text-gray-400">
        {label}
        {drive.bucket_name ? ` · ${drive.bucket_name}` : ''}
      </p>
    </div>
  )
}
