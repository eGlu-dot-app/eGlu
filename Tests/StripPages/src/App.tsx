import { useEffect, useState } from 'react'
import Dashboard from './pages/Dashboard'
import Primitives from './pages/Primitives'
import Grid from './pages/Grid'

// Test pages for the iPhone Duo's strip (Docs/iPhoneDuoDesign.md §9): real
// component libraries laying out what the strip must keep clear of.
const pages = [
  { path: '#/dashboard', title: 'Dashboard', about: 'shadcn/ui: a GitHub-like signed-in dashboard, live times, a chat button', Page: Dashboard },
  { path: '#/radix', title: 'Radix primitives', about: 'A sticky bar, accordions, popovers, selects, a scroll area, toasts', Page: Primitives },
  { path: '#/grid', title: 'AG Grid', about: 'A grid in the page, a pinned actions column, a grid that scrolls itself, live cells', Page: Grid },
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
        {pages.map((p) => (
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
