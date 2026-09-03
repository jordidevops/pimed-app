import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { cn } from '@/lib/utils'

type ChatMessageMarkdownProps = {
  content: string
  className?: string
  inverted?: boolean
}

export function ChatMessageMarkdown({ content, className, inverted }: ChatMessageMarkdownProps) {
  if (!content.trim()) return null

  return (
    <div
      className={cn(
        'prose prose-sm max-w-none break-words',
        '[&_*:first-child]:mt-0 [&_*:last-child]:mb-0',
        '[&_table]:text-xs [&_th]:px-2 [&_td]:px-2',
        inverted
          ? 'prose-invert prose-p:text-white prose-headings:text-white prose-strong:text-white prose-li:text-white prose-td:text-white prose-th:text-white prose-code:text-white'
          : 'dark:prose-invert',
        className,
      )}
    >
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          a: ({ href, children }) => (
            <a
              href={href}
              target="_blank"
              rel="noopener noreferrer"
              className="underline underline-offset-2"
            >
              {children}
            </a>
          ),
          table: ({ children }) => (
            <div className="my-2 overflow-x-auto rounded-md border">
              <table className="w-full border-collapse">{children}</table>
            </div>
          ),
          th: ({ children }) => (
            <th className="border-b bg-background/50 px-2 py-1.5 text-left font-medium">
              {children}
            </th>
          ),
          td: ({ children }) => (
            <td className="border-b px-2 py-1.5 align-top">{children}</td>
          ),
          pre: ({ children }) => (
            <pre className="overflow-x-auto rounded-md bg-background/80 p-3 text-xs">{children}</pre>
          ),
          code: ({ className: codeClassName, children, ...props }) => {
            const isBlock = Boolean(codeClassName)
            if (isBlock) {
              return (
                <code className={codeClassName} {...props}>
                  {children}
                </code>
              )
            }
            return (
              <code className="rounded bg-background/60 px-1 py-0.5 text-[0.85em]" {...props}>
                {children}
              </code>
            )
          },
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  )
}
