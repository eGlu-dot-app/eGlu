import { useEffect, useState } from 'react'
import {
  BellIcon, BugIcon, CircleDashedIcon, FileIcon, FilterIcon, GitBranchIcon, GitPullRequestIcon,
  MenuIcon, MessageCircleIcon, MoreHorizontalIcon, SearchIcon, SendIcon, SparklesIcon,
} from 'lucide-react'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Label } from '@/components/ui/label'
import { Separator } from '@/components/ui/separator'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle, SheetTrigger } from '@/components/ui/sheet'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'

// A signed-in dashboard laid out as GitHub's is: a header whose last
// buttons reach the window's edge, a pill at the right of its own row, a
// composer as wide as the page, lists whose "…" stand at the right end of
// each row, and times that change every second (GitHub's page never stops
// changing).

const pulls = [
  'iPhone Duo: the page runs on under the strip',
  'Mac extensions: NordPass signs in, no freeze on first load, no false warning, popups fit their page',
  'Keyboard: the page grows back to the window\'s foot when it goes',
  'Sync history: a day\'s changes in one list',
  'Persistent favicons for pinned tabs',
  'Reader: footnotes open in place',
]

function useNow() {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [])
  return now
}

function ago(now: number, minutes: number) {
  const seconds = Math.floor(now / 1000) % 60
  return `${minutes} minutes, ${seconds} seconds ago`
}

function RowMenu() {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" aria-label="More">
          <MoreHorizontalIcon />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem>Open</DropdownMenuItem>
        <DropdownMenuItem>Copy link</DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive">Unsubscribe</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export default function Dashboard() {
  const now = useNow()
  return (
    <div className="min-h-screen bg-background">
      <header className="flex items-center justify-between gap-2 border-b px-4 py-3">
        <div className="flex min-w-0 items-center gap-3">
          <Button variant="outline" size="icon" aria-label="Menu"><MenuIcon /></Button>
          <a href="#/" className="flex size-9 items-center justify-center rounded-full bg-foreground text-background">
            <GitBranchIcon className="size-5" />
          </a>
          <span className="truncate font-semibold">Dashboard</span>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" aria-label="Search"><SearchIcon /></Button>
          <Button variant="outline" size="icon" aria-label="Inbox" className="relative">
            <BellIcon />
            <span className="absolute -top-1 -right-1 size-2.5 rounded-full bg-blue-500" />
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button aria-label="Account" className="rounded-full">
                <Avatar className="size-9"><AvatarFallback>TP</AvatarFallback></Avatar>
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuLabel>taehee-pd</DropdownMenuLabel>
              <DropdownMenuItem>Your profile</DropdownMenuItem>
              <DropdownMenuItem>Settings</DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem>Sign out</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>

      <section className="flex items-center gap-3 border-b bg-muted/40 px-4 py-4">
        <Avatar className="size-10"><AvatarFallback>TP</AvatarFallback></Avatar>
        <div>
          <div className="font-medium">taehee-pd</div>
          <div className="text-sm text-muted-foreground">Your personal account</div>
        </div>
      </section>

      <main className="space-y-6 px-4 py-4">
        <div className="flex justify-end">
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Badge asChild variant="outline" className="cursor-pointer border-green-600 text-green-600">
                <button>Preview ▾</button>
              </Badge>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem>Leave the preview</DropdownMenuItem>
              <DropdownMenuItem>Give feedback</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>

        <h1 className="text-3xl font-semibold">Good evening, taehee-pd!</h1>

        <Card>
          <CardContent className="space-y-3">
            <Textarea placeholder="Ask anything, or describe a change" className="min-h-20" />
            <div className="flex items-center justify-between gap-2">
              <div className="flex items-center gap-1">
                <Button variant="ghost" size="sm"><SparklesIcon /> Auto</Button>
                <Button variant="ghost" size="sm">Balance</Button>
              </div>
              <Button size="icon" aria-label="Send"><SendIcon /></Button>
            </div>
          </CardContent>
        </Card>

        <div className="flex flex-wrap justify-center gap-2">
          <Button variant="outline"><BugIcon /> Debug</Button>
          <Button variant="outline"><SparklesIcon /> Agent</Button>
          <Button variant="outline"><CircleDashedIcon /> Create issue</Button>
          <Button variant="outline"><FileIcon /> Write code</Button>
          <Button variant="outline"><GitBranchIcon /> Git</Button>
        </div>

        {['Pull requests', 'Issues', 'Discussions'].map((section) => (
          <section key={section} className="space-y-2">
            <div className="flex items-center justify-between">
              <h2 className="font-medium text-muted-foreground">{section}</h2>
              <div className="flex items-center gap-1">
                <a href="#/dashboard" className="text-sm text-blue-600 hover:underline">View all</a>
                <Button variant="ghost" size="icon" aria-label="Filter"><FilterIcon /></Button>
              </div>
            </div>
            <Card className="gap-0 py-0">
              {pulls.map((title, i) => (
                <div key={title}>
                  {i > 0 && <Separator />}
                  <div className="flex items-start gap-3 p-4">
                    <GitPullRequestIcon className="mt-1 size-4 shrink-0 text-green-600" />
                    <div className="min-w-0 flex-1">
                      <a href="#/dashboard" className="font-medium hover:underline">{title}</a>
                      <p className="text-sm text-muted-foreground">
                        eGlu-dot-app/eGlu#{160 + i} · Opened by taehee-pd · Updated {ago(now, 10 + i)}
                      </p>
                    </div>
                    <RowMenu />
                  </div>
                </div>
              ))}
            </Card>
          </section>
        ))}

        <Card>
          <CardHeader>
            <CardTitle>Notifications</CardTitle>
            <CardDescription>What reaches you, and how</CardDescription>
            <CardAction><Button variant="link" size="sm">Reset</Button></CardAction>
          </CardHeader>
          <CardContent className="space-y-4">
            {['Pull request reviews', 'Comments on your issues', 'Releases you watch', 'Security alerts', 'Weekly digest'].map((name) => (
              <div key={name} className="flex items-center justify-between gap-4">
                <Label htmlFor={name}>{name}</Label>
                <Switch id={name} defaultChecked={name.length % 2 === 0} />
              </div>
            ))}
          </CardContent>
        </Card>

        <section className="space-y-3">
          <h2 className="text-lg font-semibold">Latest from our changelog</h2>
          {Array.from({ length: 12 }, (_, i) => (
            <article key={i} className="space-y-1">
              <div className="text-sm text-muted-foreground">{i + 2} days ago</div>
              <p>
                Route and orchestrate models with fewer steps: requests now pick the model that fits them, and you
                can see which one answered and why. Organisations can set which models their members may use, and
                the limits apply to every client that signs in with the organisation's accounts.
              </p>
            </article>
          ))}
        </section>
      </main>

      <Sheet>
        <SheetTrigger asChild>
          <Button size="icon" className="fixed right-4 bottom-24 size-14 rounded-full shadow-lg" aria-label="Chat">
            <MessageCircleIcon className="size-6" />
          </Button>
        </SheetTrigger>
        <SheetContent>
          <SheetHeader>
            <SheetTitle>Chat</SheetTitle>
            <SheetDescription>A fixed button at the window's corner, as chat widgets put theirs.</SheetDescription>
          </SheetHeader>
        </SheetContent>
      </Sheet>
    </div>
  )
}
