import { Image as ImageIcon } from "lucide-react";
import { type CSSProperties, type ReactNode, useMemo, useState } from "react";
import { ipc } from "@/shared/api";
import { type MdBlock, type MdInline, type MdRefs, parseMarkdown } from "@/shared/lib";

/** Which image URLs may load; the rest show as links so arbitrary servers aren't contacted */
type ImageGate = ((src: string) => boolean) | undefined;

/** Markdown drawn as React elements (macOS: MarkdownView). Links open in the browser. */
export function Markdown({ text, refs, canLoadImage, className = "", style }: { text: string; refs?: MdRefs; canLoadImage?: ImageGate; className?: string; style?: CSSProperties }) {
  const blocks = useMemo(() => parseMarkdown(text, refs), [text, refs]);
  return (
    <div className={`md selectable ${className}`} style={style}>
      <Blocks blocks={blocks} gate={canLoadImage} />
    </div>
  );
}

function Blocks({ blocks, gate }: { blocks: MdBlock[]; gate: ImageGate }) {
  return blocks.map((b, i) => <Block key={i} block={b} gate={gate} />);
}

function Block({ block: b, gate }: { block: MdBlock; gate: ImageGate }) {
  const inl = (nodes: MdInline[]) => <Inlines nodes={nodes} gate={gate} inLink={false} />;
  switch (b.kind) {
    case "paragraph":
      return <p>{inl(b.inlines)}</p>;
    case "heading": {
      const H = `h${b.level}` as "h1";
      return <H>{inl(b.inlines)}</H>;
    }
    case "code":
      return (
        <pre>
          <code>{b.text}</code>
        </pre>
      );
    case "quote":
      return (
        <blockquote>
          <Blocks blocks={b.blocks} gate={gate} />
        </blockquote>
      );
    case "list": {
      const items = b.items.map((it, i) => (
        <li key={i} className={it.task === null ? undefined : "task"}>
          {it.task !== null && <input type="checkbox" checked={it.task} disabled readOnly />}
          <Blocks blocks={it.blocks} gate={gate} />
        </li>
      ));
      return b.ordered ? <ol start={b.start}>{items}</ol> : <ul>{items}</ul>;
    }
    case "table":
      return (
        <div className="md-table">
          <table>
            <thead>
              <tr>
                {b.head.map((c, i) => (
                  <th key={i} style={{ textAlign: b.align[i] ?? undefined }}>
                    {inl(c)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {b.rows.map((r, i) => (
                <tr key={i}>
                  {r.map((c, j) => (
                    <td key={j} style={{ textAlign: b.align[j] ?? undefined }}>
                      {inl(c)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    case "details":
      return (
        <details>
          <summary>{inl(b.summary)}</summary>
          <Blocks blocks={b.blocks} gate={gate} />
        </details>
      );
    case "rule":
      return <hr />;
  }
}

function Inlines({ nodes, gate, inLink }: { nodes: MdInline[]; gate: ImageGate; inLink: boolean }) {
  return nodes.map((n, i) => <Inline key={i} node={n} gate={gate} inLink={inLink} />);
}

function Inline({ node: n, gate, inLink }: { node: MdInline; gate: ImageGate; inLink: boolean }) {
  const children = (nodes: MdInline[]) => <Inlines nodes={nodes} gate={gate} inLink={inLink} />;
  switch (n.kind) {
    case "text":
      return n.text;
    case "break":
      return <br />;
    case "code":
      return <code>{n.text}</code>;
    case "strong":
      return <strong>{children(n.children)}</strong>;
    case "em":
      return <em>{children(n.children)}</em>;
    case "strike":
      return <del>{children(n.children)}</del>;
    case "link":
      return (
        <Link href={n.href}>
          <Inlines nodes={n.children} gate={gate} inLink />
        </Link>
      );
    case "image":
      return <Image src={n.src} alt={n.alt} gate={gate} inLink={inLink} />;
  }
}

function Link({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a
      href={href}
      data-tip={href}
      onClick={(e) => {
        e.preventDefault();
        void ipc.openUrl(href);
      }}
      onAuxClick={(e) => e.preventDefault()}
    >
      {children}
    </a>
  );
}

function Image({ src, alt, gate, inLink }: { src: string; alt: string; gate: ImageGate; inLink: boolean }) {
  const [failed, setFailed] = useState(false);
  if (!failed && gate?.(src)) return <img src={src} alt={alt} loading="lazy" referrerPolicy="no-referrer" onError={() => setFailed(true)} />;
  const label = (
    <span className="md-image-alt">
      <ImageIcon size={12} />
      {alt || fileName(src)}
    </span>
  );
  return inLink ? label : <Link href={src}>{label}</Link>;
}

function fileName(src: string) {
  const last = src.split(/[?#]/)[0].split("/").pop() || src;
  try {
    return decodeURIComponent(last);
  } catch {
    return last;
  }
}
