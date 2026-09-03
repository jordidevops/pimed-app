import sanitizeHtml from "sanitize-html";

const ALLOWED_TAGS = [
  "p",
  "div",
  "section",
  "article",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "ul",
  "ol",
  "li",
  "br",
  "hr",
  "blockquote",
  "pre",
  "code",
  "a",
  "strong",
  "em",
  "b",
  "i",
  "u",
  "s",
  "span",
  "img",
  "figure",
  "figcaption",
  "table",
  "thead",
  "tbody",
  "tr",
  "th",
  "td",
];

const ALLOWED_ATTRS: sanitizeHtml.IOptions["allowedAttributes"] = {
  a: ["href", "title", "target", "rel"],
  img: ["src", "alt", "width", "height", "loading"],
  "*": ["class"],
};

export function sanitizePortalHtml(html: string): string {
  return sanitizeHtml(html, { allowedTags: ALLOWED_TAGS, allowedAttributes: ALLOWED_ATTRS });
}
