import { useEffect, useRef, useState } from 'react'
import { BellIcon, CheckIcon, MessageCircleIcon, ShoppingBagIcon, XIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Sheet, SheetClose, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import './overlays.css'

const reading = 'The shop is open throughout the week, and orders are packed each afternoon. A small team checks every item before it leaves the studio. This running text stays in the normal document flow so a browser can wrap the lines while the picture and the background continue to the edge of the window. Scroll past the product details to compare controls that move with the document with controls attached to the viewport.'

// Deliberately insert these nodes outside React, as a delayed third-party widget would.
function appendWidget(host: HTMLElement, delay: number) {
  const card = document.createElement('article')
  card.dataset.pattern = delay === 1000 ? 'overlay-late-one-second' : 'overlay-late-three-seconds'
  card.className = delay === 1000 ? 'overlay-late-card' : 'overlay-late-card overlay-dark'
  const text = document.createElement('p')
  text.textContent = delay === 1000 ? 'Your delivery estimate is ready.' : 'A specialist is available now.'
  const button = document.createElement('button')
  button.type = 'button'
  button.textContent = delay === 1000 ? 'Check delivery' : 'Start conversation'
  button.onclick = () => { text.textContent = delay === 1000 ? 'Delivery in 2 to 4 business days.' : 'You are first in the queue.' }
  card.append(text, button)
  host.append(card)
}

export default function Overlays() {
  const [scrolled, setScrolled] = useState(false)
  const [cookie, setCookie] = useState(true)
  const [notification, setNotification] = useState(true)
  const [activeOverlay, setActiveOverlay] = useState<'none' | 'modal' | 'sheet'>('none')
  const [darkDialog, setDarkDialog] = useState(false)
  const [replay, setReplay] = useState(0)
  const [cartCount, setCartCount] = useState(0)
  const [chat, setChat] = useState(false)
  const lateHost = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const onFirstScroll = () => {
      setScrolled(true)
      window.removeEventListener('scroll', onFirstScroll)
    }
    window.addEventListener('scroll', onFirstScroll, { passive: true })
    return () => window.removeEventListener('scroll', onFirstScroll)
  }, [])

  useEffect(() => {
    const host = lateHost.current
    if (!host) return
    host.replaceChildren()
    const one = window.setTimeout(() => appendWidget(host, 1000), 1000)
    const three = window.setTimeout(() => appendWidget(host, 3000), 3000)
    return () => {
      window.clearTimeout(one)
      window.clearTimeout(three)
      host.replaceChildren()
    }
  }, [replay])

  return (
    <div className="overlay-page">
      <header data-pattern="overlay-first-scroll-header" className={`overlay-scroll-header${scrolled ? ' has-scrolled' : ''}`}>
        <a href="#/">{scrolled ? 'Studio store' : 'Studio journal'}</a>
        {scrolled ? (
          <button type="button" onClick={() => setActiveOverlay('sheet')}><ShoppingBagIcon size={18} /> Bag ({cartCount})</button>
        ) : (
          <div className="overlay-header-actions">
            <button type="button" onClick={() => setNotification(true)} aria-label="Notifications"><BellIcon size={19} /></button>
            <button type="button" onClick={() => setActiveOverlay('modal')}>Sign in</button>
          </div>
        )}
      </header>

      <main>
        <section className="overlay-intro">
          <h1>Overlays and late content</h1>
          <p>Fixed notices start open. Dismiss them to inspect the sticky cart. Open the dialog and sheet separately. Delayed widgets appear after 1 and 3 seconds.</p>
          <div className="overlay-controls">
            <Button variant="outline" onClick={() => setActiveOverlay('modal')}>Open modal</Button>
            <Button variant="outline" onClick={() => setActiveOverlay('sheet')}>Open right sheet</Button>
            <Button variant="outline" onClick={() => { setCookie(true); setNotification(true) }}>Restore notices</Button>
            <Button variant="outline" onClick={() => setReplay((value) => value + 1)}>Replay late content</Button>
            <label><input type="checkbox" checked={darkDialog} onChange={(event) => setDarkDialog(event.target.checked)} /> Dark modal and sheet</label>
          </div>
        </section>

        <section className="overlay-delayed-section">
          <h2>Widgets inserted after load</h2>
          <div ref={lateHost} className="overlay-late-host" aria-live="polite" />
        </section>

        <div className="overlay-landscape" role="img" aria-label="Abstract blue and peach landscape" />

        <section className="overlay-product">
          <div className="overlay-reading">
            <h2>Everyday shoulder bag</h2>
            <p>A canvas bag with a wide shoulder strap, a zip pocket and room for a laptop. Available in blue and natural canvas.</p>
            <svg viewBox="0 0 640 320" role="img" aria-label="Canvas shoulder bag on a peach background">
              <rect width="640" height="320" fill="#e7c9b5" />
              <ellipse cx="335" cy="281" rx="151" ry="14" fill="#c5a18d" />
              <path d="M250 120V92c0-76 140-76 140 0v28" fill="none" stroke="#293e54" strokeWidth="18" />
              <path d="M211 112h218l24 160H187z" fill="#375c7e" />
              <path d="M218 121h205l17 143H200z" fill="none" stroke="#90a5b9" strokeWidth="3" />
              <rect x="285" y="182" width="70" height="38" rx="3" fill="#d9c7a9" />
            </svg>
            {Array.from({ length: 5 }, (_, i) => <p key={i}>{reading}</p>)}
          </div>
          <aside data-pattern="overlay-sticky-cart" className="overlay-cart-bar">
            <div><strong>Canvas bag</strong><span>$48.00</span></div>
            <button type="button" onClick={() => setCartCount((value) => value + 1)}><ShoppingBagIcon size={18} />{cartCount ? `Added (${cartCount})` : 'Add to cart'}</button>
          </aside>
        </section>

        <section className="overlay-reading overlay-dark">
          <h2>Evening dispatch</h2>
          <p>{reading}</p>
          <p>{reading}</p>
          <div className="overlay-landscape overlay-landscape-dark" role="img" aria-label="Abstract navy and violet landscape" />
          <p>{reading}</p>
        </section>

        <section className="overlay-reading">
          <h2>Embedded support widget</h2>
          <p>The frame is a same-origin HTML document with its own styles and buttons.</p>
          <iframe data-pattern="overlay-widget-frame" title="Support widget with buttons" src="/overlay-widget.html" className="overlay-widget-frame" />
          {Array.from({ length: 4 }, (_, i) => <p key={i}>{reading}</p>)}
        </section>
      </main>

      {cookie && (
        <aside data-pattern="overlay-cookie-banner" className="overlay-cookie" aria-label="Cookie preferences">
          <p>We use cookies to remember your preferences. <a href="#/overlays">Cookie details</a></p>
          <div>
            <button type="button" onClick={() => setCookie(false)}>Reject optional</button>
            <button type="button" className="overlay-accept" onClick={() => setCookie(false)}>Accept all</button>
            <button type="button" aria-label="Dismiss cookie notice" onClick={() => setCookie(false)}><XIcon size={18} /></button>
          </div>
        </aside>
      )}

      {notification && (
        <aside data-pattern="overlay-corner-toast" className="overlay-toast" role="status">
          <CheckIcon size={18} />
          <div><strong>All changes saved</strong><p>Your draft is ready to review.</p><button type="button" onClick={() => { setNotification(false); setActiveOverlay('modal') }}>Review</button></div>
          <button type="button" aria-label="Dismiss toast" onClick={() => setNotification(false)}><XIcon size={17} /></button>
        </aside>
      )}

      {chat && (
        <aside data-pattern="overlay-chat-panel" className="overlay-chat-panel">
          <div><strong>Studio support</strong><button type="button" aria-label="Close conversation" onClick={() => setChat(false)}><XIcon size={18} /></button></div>
          <p>How can we help with your order?</p>
          <form onSubmit={(event) => { event.preventDefault(); setChat(false) }}><input aria-label="Your message" placeholder="Type a message" /><button type="submit">Send</button></form>
        </aside>
      )}
      <button data-pattern="overlay-chat-button" type="button" className="overlay-chat-button" aria-label="Toggle support chat" aria-expanded={chat} onClick={() => setChat((value) => !value)}><MessageCircleIcon size={25} /></button>

      <Dialog open={activeOverlay === 'modal'} onOpenChange={(open) => setActiveOverlay(open ? 'modal' : 'none')}>
        <DialogContent data-pattern="overlay-close-modal" className={`overlay-modal${darkDialog ? ' dark' : ''}`}>
          <DialogHeader>
            <DialogTitle>Save your studio list</DialogTitle>
            <DialogDescription>Sign in to keep your saved products on every device.</DialogDescription>
          </DialogHeader>
          <form className="overlay-modal-form" onSubmit={(event) => { event.preventDefault(); setActiveOverlay('none'); setNotification(true) }}>
            <label htmlFor="overlay-email">Email address</label>
            <input id="overlay-email" type="email" autoComplete="email" required placeholder="you@example.com" />
            <Button type="submit">Continue</Button>
          </form>
          <DialogClose asChild><Button variant="outline">Maybe later</Button></DialogClose>
        </DialogContent>
      </Dialog>

      <Sheet open={activeOverlay === 'sheet'} onOpenChange={(open) => setActiveOverlay(open ? 'sheet' : 'none')}>
        <SheetContent data-pattern="overlay-right-sheet" className={`overlay-sheet${darkDialog ? ' dark' : ''}`} side="right">
          <SheetHeader><SheetTitle>Your shopping bag</SheetTitle><SheetDescription>{cartCount ? `${cartCount} canvas bags in your bag.` : 'Your bag is empty.'}</SheetDescription></SheetHeader>
          <div className="overlay-sheet-body"><p>{reading}</p><label htmlFor="overlay-note">Order note</label><textarea id="overlay-note" placeholder="Add delivery instructions" /></div>
          <div className="overlay-sheet-footer"><SheetClose asChild><Button variant="outline">Keep shopping</Button></SheetClose><Button onClick={() => { setActiveOverlay('none'); setNotification(true) }}>Checkout</Button></div>
        </SheetContent>
      </Sheet>
    </div>
  )
}
