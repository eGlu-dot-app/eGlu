import { useState } from 'react'
import { ChevronDownIcon, ChevronLeftIcon, ChevronRightIcon, FilterIcon, MoreVerticalIcon, SearchIcon, SendIcon } from 'lucide-react'
import { Switch } from '@/components/ui/switch'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import './sections.css'

type Tone = 'light' | 'dark'

const topics = ['For you', 'Following', 'Engineering', 'Product design', 'Open source', 'Accessibility', 'Releases', 'Security']

function RunningText() {
  return (
    <p className="sp-section-copy">
      Our team keeps product notes alongside the work they describe. A short update can start a conversation,
      explain a decision, or point someone to a pull request they have not seen. Longer notes stay in the same
      reading order as the rest of the page, with ordinary sentences that wrap naturally as the window changes.
      Readers can keep scrolling while the cards, controls, and images appear between these paragraphs.
    </p>
  )
}

function Landscape({ tone }: { tone: Tone }) {
  return (
    <svg className="sp-section-image" viewBox="0 0 900 220" role="img" aria-label="Abstract hills in a wide landscape">
      <rect width="900" height="220" fill={tone === 'light' ? '#bde5f5' : '#182a4c'} />
      <circle cx="740" cy="65" r="32" fill={tone === 'light' ? '#f8df88' : '#d6ddff'} />
      <path d="M0 170 Q160 40 350 160 T700 125 T900 145 V220 H0Z" fill={tone === 'light' ? '#83bfa7' : '#365a6d'} />
      <path d="M0 210 Q210 115 420 190 T900 170 V220 H0Z" fill={tone === 'light' ? '#4a887b' : '#213c45'} />
    </svg>
  )
}

function SectionStack({ tone }: { tone: Tone }) {
  const [message, setMessage] = useState('')
  const [filter, setFilter] = useState(false)
  const [draft, setDraft] = useState('')
  const [subscribed, setSubscribed] = useState(true)
  const [invited, setInvited] = useState(false)
  const [topic, setTopic] = useState('For you')
  const [page, setPage] = useState(1)
  const [segment, setSegment] = useState('Overview')
  const [search, setSearch] = useState('')
  const pattern = (name: string) => `section-${name}-${tone}`

  return (
    <section className={`sp-section-stack sp-section-${tone}${tone === 'dark' ? ' dark' : ''}`} aria-label={`${tone} section and card patterns`}>
      <div className="sp-section-intro">
        <h2>{tone === 'light' ? 'Light' : 'Dark'} sections and cards</h2>
        <p>Native controls, Radix controls, absolute positioning, CSS grid, floats, and ordinary form layouts.</p>
      </div>

      <section className="sp-section-block">
        <div data-pattern={pattern('pulls')} className="sp-section-pulls">
          <h3>Pull requests</h3>
          <div className="sp-section-heading-actions">
            <a href="#/sections" onClick={(event) => { event.preventDefault(); setMessage('Showing all pull requests') }}>View all</a>
            <button className="sp-section-icon" aria-label="Filter pull requests" aria-pressed={filter} onClick={() => setFilter(!filter)}><FilterIcon /></button>
          </div>
        </div>
        <ul className="sp-section-pull-list">
          {(filter ? ['Review requested: improve the reading layout'] : ['Review requested: improve the reading layout', 'Keep account settings across windows', 'Add keyboard navigation to the activity list']).map((title) => <li key={title}><a href="#/sections" onClick={(event) => { event.preventDefault(); setMessage(title) }}>{title}</a><small>Updated a few minutes ago</small></li>)}
        </ul>
      </section>

      <section data-pattern={pattern('preview')} className="sp-section-preview sp-section-block">
        <div className="sp-section-preview-row">
          <DropdownMenu>
            <DropdownMenuTrigger asChild><button className="sp-section-pill">Preview <ChevronDownIcon /></button></DropdownMenuTrigger>
            <DropdownMenuContent align="end"><DropdownMenuItem onSelect={() => setMessage('Preview feedback selected')}>Give feedback</DropdownMenuItem><DropdownMenuItem onSelect={() => setMessage('Preview remains available for testing')}>About this preview</DropdownMenuItem></DropdownMenuContent>
          </DropdownMenu>
        </div>
        <h3>What would you like to build?</h3>
        <p>The preview control is in its own right-aligned row above the heading.</p>
      </section>

      <form data-pattern={pattern('composer')} className="sp-section-composer sp-section-block" onSubmit={(event) => { event.preventDefault(); setMessage(draft.trim() ? `Sent with the selected model: ${draft}` : 'Enter a message before sending'); if (draft.trim()) setDraft('') }}>
        <label className="sp-section-field-label" htmlFor={`composer-${tone}`}>Ask a question</label>
        <textarea id={`composer-${tone}`} value={draft} onChange={(event) => setDraft(event.target.value)} placeholder="Describe a change or ask about your code" rows={4} />
        <div className="sp-section-composer-footer">
          <div className="sp-section-models"><select aria-label="Model"><option>Auto model</option><option>Fast model</option><option>Reasoning model</option></select><button type="button" className="sp-section-text-button" onClick={() => setMessage('Balanced mode selected')}>Balanced</button></div>
          <button type="submit" className="sp-section-send" aria-label="Send message"><SendIcon /></button>
        </div>
      </form>

      <RunningText />
      <Landscape tone={tone} />

      <article data-pattern={pattern('kebab-card')} className="sp-section-kebab-card sp-section-block">
        <DropdownMenu>
          <DropdownMenuTrigger asChild><button className="sp-section-icon sp-section-kebab" aria-label="More card actions"><MoreVerticalIcon /></button></DropdownMenuTrigger>
          <DropdownMenuContent align="end"><DropdownMenuItem onSelect={() => setMessage('Card link copied for this demo')}>Copy link</DropdownMenuItem><DropdownMenuItem onSelect={() => setMessage('Card saved')}>Save card</DropdownMenuItem></DropdownMenuContent>
        </DropdownMenu>
        <h3>Weekly product notes</h3>
        <p>Changes to the reader, page controls, and saved work. The card menu is positioned independently at the top-right corner.</p>
        <a href="#/sections" onClick={(event) => { event.preventDefault(); setMessage('Weekly product notes opened') }}>Read the update</a>
      </article>

      <div className="sp-section-block sp-section-rows">
        <div data-pattern={pattern('switch-row')} className="sp-section-switch-row"><label htmlFor={`updates-${tone}`}>Product updates<small>Send a weekly email</small></label><Switch id={`updates-${tone}`} checked={subscribed} onCheckedChange={setSubscribed} /></div>
        <div data-pattern={pattern('badge-row')} className="sp-section-badge-row"><span>Design system<small>Shared with the product team</small></span><a className="sp-section-badge" href="#/sections" onClick={(event) => { event.preventDefault(); setMessage('Team plan details opened') }}>Team plan</a></div>
        <div data-pattern={pattern('button-row')} className="sp-section-button-row"><span>Project members<small>8 people have access</small></span><button className="sp-section-button" onClick={() => setInvited(!invited)}>{invited ? 'Invited' : 'Invite'}</button></div>
      </div>

      <nav data-pattern={pattern('chips')} className="sp-section-chips" aria-label={`${tone} topic filters`}>
        {topics.map((name) => <button key={name} className="sp-section-chip" aria-pressed={topic === name} onClick={() => setTopic(name)}>{name}</button>)}
      </nav>
      <p className="sp-section-selected">Selected topic: {topic}</p>

      <nav data-pattern={pattern('pagination')} className="sp-section-pagination" aria-label={`${tone} result pages`}>
        <button className="sp-section-icon" aria-label="Previous page" disabled={page === 1} onClick={() => setPage(page - 1)}><ChevronLeftIcon /></button>
        {[1, 2, 3, 4, 5].map((number) => <button key={number} className="sp-section-page-number" aria-current={page === number ? 'page' : undefined} onClick={() => setPage(number)}>{number}</button>)}
        <button className="sp-section-icon" aria-label="Next page" disabled={page === 5} onClick={() => setPage(page + 1)}><ChevronRightIcon /></button>
      </nav>
      <p className="sp-section-selected">Page {page} of 5</p>

      <div data-pattern={pattern('segmented')} className="sp-section-segmented">
        <ToggleGroup type="single" value={segment} onValueChange={(value) => { if (value) setSegment(value) }} variant="outline" spacing={0} aria-label="Activity view">
          {['Overview', 'Activity', 'Settings'].map((name) => <ToggleGroupItem key={name} value={name}>{name}</ToggleGroupItem>)}
        </ToggleGroup>
        <p>{segment === 'Overview' ? 'Your projects and recent work.' : segment === 'Activity' ? 'Recent comments and review requests.' : 'Account and project preferences.'}</p>
      </div>

      <form data-pattern={pattern('search')} className="sp-section-search" role="search" onSubmit={(event) => { event.preventDefault(); setMessage(`Search results for ${search || 'all projects'}`) }}>
        <label className="sp-section-field-label" htmlFor={`search-${tone}`}>Search projects</label>
        <div className="sp-section-search-field"><input id={`search-${tone}`} type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search all projects" /><button type="submit" className="sp-section-icon" aria-label="Search projects"><SearchIcon /></button></div>
      </form>

      <RunningText />

      <table data-pattern={pattern('actions-table')} className="sp-section-table">
        <caption>Recent deployments</caption>
        <thead><tr><th>Project</th><th>Status</th><th>Actions</th></tr></thead>
        <tbody>{['Reader', 'Workspace', 'Account'].map((name, index) => <tr key={name}><td>{name}</td><td><span className="sp-section-badge">{index === 1 ? 'Building' : 'Ready'}</span></td><td><button className="sp-section-text-button" onClick={() => setMessage(`${name} deployment opened`)}>View</button></td></tr>)}</tbody>
      </table>

      <form data-pattern={pattern('form')} className="sp-section-form sp-section-block" onSubmit={(event) => { event.preventDefault(); setMessage('Profile changes saved') }}>
        <h3>Public profile</h3>
        <label htmlFor={`display-name-${tone}`}>Display name</label><input id={`display-name-${tone}`} defaultValue="Taehee" />
        <label htmlFor={`bio-${tone}`}>Bio</label><textarea id={`bio-${tone}`} rows={3} defaultValue="Product designer working on useful tools." />
        <div className="sp-section-form-actions"><button type="reset" className="sp-section-button" onClick={() => setMessage('Profile reset')}>Cancel</button><button className="sp-section-button sp-section-primary" type="submit">Save changes</button></div>
      </form>

      <div className="sp-section-feedback" role="status">{message || 'Use any control to see its result here.'}</div>
      <RunningText />
      <div className="sp-section-gradient" role="img" aria-label="Full-width blue and violet gradient" />
    </section>
  )
}

export default function Sections() {
  return (
    <main className="sp-sections">
      <header className="sp-section-page-heading"><a href="#/">All test pages</a><h1>Section headings and cards</h1><p>Two complete stacks with different heading, card, list, and form layouts. Page content reaches the window edges.</p></header>
      <SectionStack tone="light" />
      <SectionStack tone="dark" />
    </main>
  )
}
