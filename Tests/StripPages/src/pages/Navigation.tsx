import { createElement, useEffect, useState, type ReactNode } from 'react'
import {
  Bell, ChevronDown, CircleHelp, Grid3X3, Inbox, Menu, Mic, Plus, Search,
  Settings, ShoppingBag, ShoppingCart,
} from 'lucide-react'
import './navigation.css'

// The host is a real custom element, not a React imitation of shadow DOM.
// Registration survives StrictMode mounts and Vite hot reloads.
if (!customElements.get('strip-nav-actions')) {
  class StripNavActions extends HTMLElement {
    connectedCallback() {
      if (this.shadowRoot) return
      const root = this.attachShadow({ mode: 'open' })
      root.innerHTML = `
        <style>
          :host { display: block; flex: 0 0 auto; }
          .actions { display: flex; align-items: center; gap: 7px; }
          button { position: relative; width: 32px; height: 32px; border: 0;
            border-radius: 50%; color: inherit; background: transparent; cursor: pointer; }
          button:hover { background: #8883; }
          svg { width: 19px; height: 19px; vertical-align: middle; }
          .avatar { background: #b9d3fa; color: #163765; font: bold 11px system-ui; }
        </style>
        <div class="actions">
          <button aria-label="Help"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M9 9a3 3 0 0 1 6 0c0 2-3 2-3 5m0 2v1"/></svg></button>
          <button aria-label="Settings"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="4"/><path d="M12 1v4m0 14v4M1 12h4m14 0h4M4 4l3 3m10 10 3 3M4 20l3-3M17 7l3-3"/></svg></button>
          <button aria-label="Google apps"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 3h4v4H3zm7 0h4v4h-4zm7 0h4v4h-4zM3 10h4v4H3zm7 0h4v4h-4zm7 0h4v4h-4zM3 17h4v4H3zm7 0h4v4h-4zm7 0h4v4h-4z"/></svg></button>
          <button class="avatar" aria-label="Google account">TP</button>
        </div>`
      root.querySelectorAll('button').forEach((button) => {
        button.addEventListener('click', () => {
          this.dispatchEvent(new CustomEvent('nav-action', {
            bubbles: true, composed: true, detail: button.getAttribute('aria-label'),
          }))
          button.dataset.clicked = String(Number(button.dataset.clicked ?? 0) + 1)
        })
      })
    }
  }
  customElements.define('strip-nav-actions', StripNavActions)
}

function GithubMark() {
  return <svg aria-label="GitHub" role="img" viewBox="0 0 24 24" width="30" height="30" fill="currentColor"><path d="M12 .3a12 12 0 0 0-3.8 23.4c.6.1.8-.3.8-.6v-2.2c-3.3.7-4-1.4-4-1.4-.5-1.4-1.3-1.7-1.3-1.7-1.1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1.1 1.8 2.8 1.3 3.5 1 .1-.8.4-1.3.8-1.6-2.7-.3-5.5-1.3-5.5-5.9 0-1.3.5-2.4 1.2-3.2-.1-.3-.5-1.6.1-3.2 0 0 1-.3 3.3 1.2a11.4 11.4 0 0 1 6 0c2.3-1.5 3.3-1.2 3.3-1.2.6 1.6.2 2.9.1 3.2.8.8 1.2 1.9 1.2 3.2 0 4.6-2.8 5.6-5.5 5.9.5.4.8 1.1.8 2.2v3.2c0 .3.2.7.8.6A12 12 0 0 0 12 .3Z" /></svg>
}

function AppleMark() {
  return <svg viewBox="0 0 24 24" width="22" height="22" aria-label="Apple" role="img" fill="currentColor"><path d="M16.5 1c.1 2-1.4 3.8-3.1 4 .1-1.9 1.5-3.6 3.1-4Zm3.8 16.6c-.5 1.2-.8 1.8-1.5 2.8-.9 1.2-2.1 2.6-3.5 2.6-1.3 0-1.7-.8-3.5-.8s-2.2.8-3.5.8C6.9 23 5.8 21.7 5 20.5c-2.4-3.4-2.7-7.5-1.2-9.7 1.1-1.5 2.8-2.4 4.4-2.4 1.4 0 2.4.8 3.5.8s1.9-.8 3.5-.8c1.3 0 2.6.7 3.6 1.9-3.2 1.8-2.7 6.2 1.5 7.3Z" /></svg>
}

type Action = (label: string) => void

function IconButton({ label, children, action, className = '' }: {
  label: string; children: ReactNode; action: Action; className?: string
}) {
  return <button type="button" className={`nv-icon ${className}`} aria-label={label} onClick={() => action(label)}>{children}</button>
}

function Avatar({ action }: { action: Action }) {
  return <IconButton label="Your profile" action={action} className="nv-avatar">TP</IconButton>
}

function Github({ action }: { action: Action }) {
  return <>
    <div className="nv-left">
      <IconButton label="Open global navigation" action={action}><Menu /></IconButton>
      <a href="#/" className="nv-brand" aria-label="GitHub home"><GithubMark /></a>
      <strong>Dashboard</strong>
    </div>
    <div className="nv-right">
      <IconButton label="Search GitHub" action={action}><Search /></IconButton>
      <IconButton label="Inbox" action={action} className="nv-inbox"><Inbox /><span className="nv-blue-dot" /></IconButton>
      <Avatar action={action} />
    </div>
  </>
}

function Youtube({ action }: { action: Action }) {
  return <>
    <div className="nv-left"><IconButton label="Menu" action={action}><Menu /></IconButton><a href="#/" className="nv-youtube"><span className="nv-play">▶</span><b>YouTube</b></a></div>
    <div className="nv-right">
      <IconButton label="Voice search" action={action}><Mic /></IconButton>
      <button className="nv-create" onClick={() => action('Create video')}><Plus size={16} /> Create</button>
      <IconButton label="Notifications, 9 unread" action={action} className="nv-inbox"><Bell /><span className="nv-count">9</span></IconButton>
      <Avatar action={action} />
    </div>
  </>
}

function Gmail({ action, shadow = false }: { action: Action; shadow?: boolean }) {
  return <>
    <div className="nv-left"><IconButton label="Main menu" action={action}><Menu /></IconButton><span className="nv-gmail">M</span></div>
    <label className="nv-search-pill"><Search size={17} /><input aria-label="Search mail" placeholder="Search mail" /></label>
    {shadow ? createElement('strip-nav-actions') : <div className="nv-right nv-gmail-actions">
      <IconButton label="Help" action={action}><CircleHelp /></IconButton>
      <IconButton label="Settings" action={action}><Settings /></IconButton>
      <IconButton label="Google apps" action={action}><Grid3X3 /></IconButton>
      <Avatar action={action} />
    </div>}
  </>
}

function Amazon({ action, divs = false }: { action: Action; divs?: boolean }) {
  const cart = <><ShoppingCart /><span className="nv-cart-count">3</span><b>Cart</b></>
  return <>
    <a href="#/" className="nv-amazon-logo">amazon<span>.com</span></a>
    <span className="nv-delivery">Deliver to<br /><b>Korea</b></span>
    <div className="nv-right nv-amazon-actions">
      {divs ? <>
        <DivClick label="Account" action={action}>Hello, Taehee<ChevronDown size={13} /></DivClick>
        <DivClick label="Cart" action={action}>{cart}</DivClick>
      </> : <>
        <button className="nv-account" onClick={() => action('Account')}>Hello, Taehee<br /><b>Account &amp; Lists</b></button>
        <button className="nv-cart" onClick={() => action('Cart')}>{cart}</button>
      </>}
    </div>
  </>
}

function DivClick({ label, children, action }: { label: string; children: ReactNode; action: Action }) {
  return <div title={label} className="nv-div-click" ref={(node) => {
    if (!node) return
    // Keep a literal onclick attribute for selectors that inspect legacy sites.
    node.setAttribute('onclick', 'void 0')
    node.onclick = () => action(label)
  }}>{children}</div>
}

function News({ action }: { action: Action }) {
  return <>
    <div className="nv-left"><IconButton label="Sections" action={action}><Menu /></IconButton><a href="#/" className="nv-news-logo">The Daily Record</a></div>
    <div className="nv-right"><button className="nv-subscribe" onClick={() => action('Subscribe')}>Subscribe</button></div>
  </>
}

function Apple({ action, links = false }: { action: Action; links?: boolean }) {
  return <>
    <a href="#/" aria-label="Apple home"><AppleMark /></a>
    <a href="#/" className="nv-apple-store">Store</a>
    <div className="nv-right nv-apple-actions">
      {links ? <>
        <a role="button" href="#search" aria-label="Search" onClick={(event) => { event.preventDefault(); action('Search') }}><Search /></a>
        <a role="button" href="#bag" aria-label="Shopping bag" onClick={(event) => { event.preventDefault(); action('Shopping bag') }}><ShoppingBag /></a>
        <a role="button" href="#menu" aria-label="Menu" onClick={(event) => { event.preventDefault(); action('Menu') }}><Menu /></a>
      </> : <>
        <IconButton label="Search Apple" action={action}><Search /></IconButton>
        <IconButton label="Shopping bag" action={action}><ShoppingBag /></IconButton>
        <IconButton label="Menu" action={action}><Menu /></IconButton>
      </>}
    </div>
  </>
}

const variants = [
  { key: 'github-between', title: 'GitHub signed in', technique: 'Flex space-between', style: 'nv-between nv-github' },
  { key: 'youtube-auto', title: 'YouTube', technique: 'Right group margin-left: auto', style: 'nv-auto' },
  { key: 'gmail-grid', title: 'Gmail', technique: 'Grid auto 1fr auto', style: 'nv-grid nv-mail' },
  { key: 'amazon-absolute', title: 'Amazon', technique: 'Absolute right: 16px', style: 'nv-absolute nv-amazon' },
  { key: 'news-float', title: 'News', technique: 'Legacy float: right', style: 'nv-float nv-news' },
  { key: 'youtube-wrap', title: 'YouTube', technique: 'Right group wraps at a narrow width', style: 'nv-wrap' },
  { key: 'news-two-row', title: 'News utility and main rows', technique: 'Two independent rows', style: 'nv-two-row nv-news' },
  { key: 'github-tabs', title: 'GitHub repository', technique: 'Header with horizontal overflow tabs', style: 'nv-tabs nv-github' },
  { key: 'news-compact', title: 'News compact on scroll', technique: 'Scroll listener toggles compact class', style: 'nv-between nv-news nv-compacting' },
  { key: 'apple-backdrop', title: 'Apple glass header', technique: 'Fixed backdrop-filter, flow comparison', style: 'nv-auto nv-apple nv-backdrop' },
  { key: 'gmail-shadow', title: 'Gmail shadow controls', technique: 'Custom element with an open shadow root', style: 'nv-grid nv-mail' },
  { key: 'apple-role-links', title: 'Apple anchor controls', technique: 'Plain a[role=button] tags', style: 'nv-auto nv-apple' },
  { key: 'amazon-onclick', title: 'Amazon legacy controls', technique: 'Div onclick, cursor pointer, no role', style: 'nv-auto nv-amazon' },
  { key: 'naver-search', title: 'Naver search', technique: 'Full-width search form below utility links', style: 'nv-naver' },
]

type Variant = typeof variants[number]

function BarContents({ variant, action }: { variant: Variant; action: Action }) {
  switch (variant.key) {
    case 'github-between': return <Github action={action} />
    case 'youtube-auto':
    case 'youtube-wrap': return <Youtube action={action} />
    case 'gmail-grid': return <Gmail action={action} />
    case 'gmail-shadow': return <Gmail action={action} shadow />
    case 'amazon-absolute': return <Amazon action={action} />
    case 'amazon-onclick': return <Amazon action={action} divs />
    case 'news-float':
    case 'news-compact': return <News action={action} />
    case 'news-two-row': return <>
      <div className="nv-utility"><a href="#/">Today's paper</a><span>Tuesday, November 3</span><button onClick={() => action('Sign in')}>Sign in</button></div>
      <div className="nv-main-row"><News action={action} /></div>
    </>
    case 'github-tabs': return <>
      <div className="nv-main-row"><Github action={action} /></div>
      <nav className="nv-repo-tabs" aria-label="Repository"><a href="#/">Code</a><a href="#/">Issues <span>24</span></a><a href="#/">Pull requests <span>8</span></a><a href="#/">Actions</a><a href="#/">Projects</a><a href="#/">Security</a><a href="#/">Insights</a><a href="#/">Settings</a></nav>
    </>
    case 'apple-backdrop': return <Apple action={action} />
    case 'apple-role-links': return <Apple action={action} links />
    case 'naver-search': return <>
      <div className="nv-naver-utility"><a href="#/">NAVER</a><div className="nv-right"><IconButton label="Naver services" action={action}><Grid3X3 /></IconButton><Avatar action={action} /></div></div>
      <form className="nv-naver-search" onSubmit={(event) => { event.preventDefault(); action('Search Naver') }}><span className="nv-naver-n" aria-hidden="true">N</span><input aria-label="Search Naver" placeholder="Search Naver" /><button aria-label="Submit Naver search"><Search /></button></form>
    </>
    default: return null
  }
}

function RunningContent({ title }: { title: string }) {
  return <div className="nv-running">
    <div className="nv-landscape" role="img" aria-label="Abstract landscape with a blue sky and green hillside" />
    <p>{title} sits above a normal article. The page uses its entire width for text, pictures and backgrounds. A reader can continue down the article while the navigation controls stay near the edge. Longer sentences cross the same part of the window as account menus, search controls and notification buttons.</p>
    <p>These paragraphs have no links or buttons. Their wrapping and the full-width image are useful comparisons when a browser moves nearby controls. The image has no reserved margin on either side, and the article text follows the width of its container.</p>
  </div>
}

export default function Navigation() {
  const [lastAction, setLastAction] = useState('No action yet')
  useEffect(() => {
    const headers = document.querySelectorAll<HTMLElement>('.nv-compacting')
    const scrolled = () => headers.forEach((header) => {
      // Each sample compacts as it approaches the top, rather than before
      // the reader has reached this family far down the page.
      header.classList.toggle('compact', header.getBoundingClientRect().top < 120)
    })
    const shadowAction = (event: Event) => {
      if (event instanceof CustomEvent && typeof event.detail === 'string') setLastAction(event.detail)
    }
    window.addEventListener('scroll', scrolled, { passive: true })
    window.addEventListener('nav-action', shadowAction)
    return () => {
      window.removeEventListener('scroll', scrolled)
      window.removeEventListener('nav-action', shadowAction)
    }
  }, [])
  const action: Action = (label) => setLastAction(`${label} clicked`)

  return <main className="navigation-fixtures">
    <div className="nv-intro"><a href="#/">All test pages</a><h1>Global navigation layouts</h1><p>14 layout families, each in flow and sticky or fixed. Scroll through each sample. The fixed Apple bar at the top can be hidden to inspect the bars below it.</p><output aria-live="polite">Last action: {lastAction}</output></div>
    {variants.map((variant, index) => <section key={variant.key} className="nv-family">
      <div className="nv-sample-label"><h2>{index + 1}. {variant.title}</h2><p>{variant.technique}</p></div>
      {(['flow', 'pinned'] as const).map((mode) => {
        const position = mode === 'flow' ? 'flow' : variant.key === 'apple-backdrop' ? 'fixed' : 'sticky'
        const dark = (index + (mode === 'pinned' ? 1 : 0)) % 2 === 1
        return <div className={`nv-sample ${dark ? 'nv-dark' : ''}`} key={mode}>
          <p className="nv-mode-label">{position}. {dark ? 'Dark' : 'Light'}.</p>
          <header data-pattern={`nav-${variant.key}-${position}`} className={`nv-bar ${variant.style} nv-${position}`}>
            <BarContents variant={variant} action={action} />
            {position === 'fixed' && <button className="nv-fixed-hide" onClick={(event) => { const header = event.currentTarget.closest('header'); if (header) header.hidden = true }}>Hide fixed bar</button>}
          </header>
          <RunningContent title={variant.title} />
        </div>
      })}
    </section>)}
    <p className="nv-end"><a href="#/">All test pages</a>. Reload this route to restore the fixed header.</p>
  </main>
}
