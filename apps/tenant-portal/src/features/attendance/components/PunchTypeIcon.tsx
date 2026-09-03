import { LogIn, LogOut, Coffee, Car, Flag, PlayCircle, MapPin } from 'lucide-react'
import { cn } from '@/lib/utils'

export function PunchTypeIcon({
  punchType,
  className,
}: {
  punchType: string
  className?: string
}) {
  const iconClass = cn('h-3.5 w-3.5 shrink-0', className)
  switch (punchType) {
    case 'in':
      return <LogIn className={cn(iconClass, 'text-emerald-600')} aria-hidden />
    case 'break_start':
    case 'break_end':
      return <Coffee className={cn(iconClass, 'text-amber-600')} aria-hidden />
    case 'day_start':
      return <PlayCircle className={cn(iconClass, 'text-sky-600')} aria-hidden />
    case 'day_end':
      return <Flag className={cn(iconClass, 'text-slate-600')} aria-hidden />
    case 'travel_start':
      return <Car className={cn(iconClass, 'text-violet-600')} aria-hidden />
    case 'travel_end':
      return <MapPin className={cn(iconClass, 'text-violet-600')} aria-hidden />
    default:
      return <LogOut className={cn(iconClass, 'text-slate-500')} aria-hidden />
  }
}
