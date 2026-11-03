import { useEffect, useState } from 'react'
import Dashboard from './pages/Dashboard'
import Primitives from './pages/Primitives'
import Grid from './pages/Grid'
import Navigation from './pages/Navigation'
import Sections from './pages/Sections'
import Overlays from './pages/Overlays'

// Test pages for the iPhone Duo's strip (Docs/iPhoneDuoDesign.md §9): real
// component libraries laying out what the strip must keep clear of.
const pages = [
  { path: '#/dashboard', title: 'Dashboard', about: 'shadcn/ui: a GitHub-like signed-in dashboard, live times, a chat button', Page: Dashboard },
  { path: '#/radix', title: 'Radix primitives', about: 'A sticky bar, accordions, popovers, selects, a scroll area, toasts', Page: Primitives },
  { path: '#/grid', title: 'AG Grid', about: 'A grid in the page, a pinned actions column, a grid that scrolls itself, live cells', Page: Grid },
  { path: '#/navigation', title: 'Global navigation layouts', about: '28 real-site headers: flow, sticky, fixed, floats, wrapping, shadow DOM and legacy controls', Page: Navigation },
  { path: '#/sections', title: 'Section headings and cards', about: 'Light and dark headings, composer cards, trailing controls, chips, tables and forms', Page: Sections },
  { path: '#/overlays', title: 'Overlays and late content', about: 'Fixed notices, modal, right sheet, cart bar, chat, timed insertions and an iframe widget', Page: Overlays },
]

const publicPages = [
  { path: '/github-signed-in.html', title: 'GitHub signed in, header first', about: "GitHub's header at the very top, its custom elements, a live feed; ?late=avatar or ?late=header brings the bar's end in late" },
  { path: '/github-header.html', title: 'Plain HTML GitHub', about: 'Static signed-in headers with notification dots and pull request actions in light and dark' },
  { path: '/bootstrap-navbar.html', title: 'Plain HTML Bootstrap', about: 'Hand-written responsive navbars with collapse, dropdown and search controls' },
  { path: '/rtl.html', title: 'Plain HTML right to left', about: 'Arabic right-to-left headers and trailing controls for testing the opposite strip side' },
  { path: '/overlay-widget.html', title: 'Plain HTML widget', about: 'The overlay page iframe content, with a toolbar, search field and local action buttons' },
  { path: '/scroll-probe.html', title: 'Scroll probe', about: 'How far a flick goes on, and whether a touch stops it; ?handler=1 adds a touch listener that is not passive' },
  { path: '/probe.html', title: 'Strip probe', about: 'The existing plain HTML strip probe and layout diagnostics' },
]

export default function App() {
  const [hash, setHash] = useState(location.hash)
  useEffect(() => {
    const changed = () => {
      setHash(location.hash)
      window.scrollTo(0, 0)
    }
    window.addEventListener('hashchange', changed)
    return () => window.removeEventListener('hashchange', changed)
  }, [])
  const page = pages.find((p) => p.path === hash)
  if (page) return <page.Page />
  return (
    <main className="mx-auto max-w-2xl p-4">
      <h1 className="mb-4 text-2xl font-semibold">Strip test pages</h1>
      <ul className="space-y-2">
        {[...pages, ...publicPages].map((p) => (
          <li key={p.path}>
            <a className="block rounded-lg border p-3 hover:bg-muted" href={p.path}>
              <div className="font-medium">{p.title}</div>
              <div className="text-sm text-muted-foreground">{p.about}</div>
            </a>
          </li>
        ))}
      </ul>
    </main>
  )
}
