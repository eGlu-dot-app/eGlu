import { CircleHelpIcon, InfoIcon, PlusIcon, SettingsIcon, Trash2Icon } from 'lucide-react'
import { toast } from 'sonner'
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  NavigationMenu, NavigationMenuContent, NavigationMenuItem, NavigationMenuLink, NavigationMenuList, NavigationMenuTrigger,
} from '@/components/ui/navigation-menu'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { ScrollArea, ScrollBar } from '@/components/ui/scroll-area'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Slider } from '@/components/ui/slider'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'

// Radix's primitives as shadcn/ui draws them: a sticky bar whose controls
// end at the window's edge, accordions with their chevrons at the right,
// popovers and tooltips on icons at the right, a slider as wide as the page,
// a row of chips that scrolls sideways, a wide table, and toasts from the
// window's corner.

const chips = ['All', 'Design', 'Engineering', 'Marketing', 'Sales', 'Support', 'Legal', 'Finance', 'People', 'Research']

export default function Primitives() {
  return (
    <div className="min-h-screen bg-background">
      <div className="sticky top-0 z-10 flex items-center justify-between gap-2 border-b bg-background/90 px-4 py-2 backdrop-blur">
        <NavigationMenu>
          <NavigationMenuList>
            <NavigationMenuItem>
              <NavigationMenuTrigger>Products</NavigationMenuTrigger>
              <NavigationMenuContent>
                <ul className="grid w-64 gap-1 p-2">
                  {['Analytics', 'Automation', 'Reports'].map((name) => (
                    <li key={name}><NavigationMenuLink href="#/radix">{name}</NavigationMenuLink></li>
                  ))}
                </ul>
              </NavigationMenuContent>
            </NavigationMenuItem>
          </NavigationMenuList>
        </NavigationMenu>
        <div className="flex items-center gap-1">
          <Select defaultValue="week">
            <SelectTrigger size="sm" className="w-28"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="day">Today</SelectItem>
              <SelectItem value="week">This week</SelectItem>
              <SelectItem value="month">This month</SelectItem>
            </SelectContent>
          </Select>
          <Button variant="ghost" size="icon" aria-label="Settings"><SettingsIcon /></Button>
        </div>
      </div>

      <main className="space-y-8 px-4 py-4">
        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h1 className="text-2xl font-semibold">Team overview</h1>
            <Popover>
              <PopoverTrigger asChild>
                <Button variant="ghost" size="icon" aria-label="Help"><CircleHelpIcon /></Button>
              </PopoverTrigger>
              <PopoverContent align="end" className="w-64 text-sm">
                The numbers count the week from Monday, in your own time zone.
              </PopoverContent>
            </Popover>
          </div>
          <ScrollArea className="w-full whitespace-nowrap">
            <ToggleGroup type="single" defaultValue="All" variant="outline" className="w-max">
              {chips.map((chip) => <ToggleGroupItem key={chip} value={chip}>{chip}</ToggleGroupItem>)}
            </ToggleGroup>
            <ScrollBar orientation="horizontal" />
          </ScrollArea>
        </section>

        <Tabs defaultValue="members">
          <TabsList className="w-full">
            <TabsTrigger value="members">Members</TabsTrigger>
            <TabsTrigger value="invites">Invites</TabsTrigger>
            <TabsTrigger value="roles">Roles</TabsTrigger>
          </TabsList>
          <TabsContent value="members" className="space-y-3 pt-2">
            {['Ada Lovelace', 'Grace Hopper', 'Alan Kay', 'Margaret Hamilton', 'Dennis Ritchie'].map((name) => (
              <div key={name} className="flex items-center justify-between gap-2">
                <div className="flex items-center gap-2">
                  <Checkbox id={name} />
                  <Label htmlFor={name}>{name}</Label>
                </div>
                <div className="flex items-center gap-1">
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <Button variant="ghost" size="icon" aria-label="About"><InfoIcon /></Button>
                    </TooltipTrigger>
                    <TooltipContent>Joined in March</TooltipContent>
                  </Tooltip>
                  <Button variant="ghost" size="icon" aria-label="Remove" onClick={() => toast(`${name} removed`)}>
                    <Trash2Icon />
                  </Button>
                </div>
              </div>
            ))}
          </TabsContent>
          <TabsContent value="invites" className="pt-2 text-sm text-muted-foreground">No invites waiting.</TabsContent>
          <TabsContent value="roles" className="pt-2 text-sm text-muted-foreground">Owner, Member, Guest.</TabsContent>
        </Tabs>

        <section className="space-y-2">
          <Label>Volume</Label>
          <Slider defaultValue={[60]} max={100} step={1} />
        </section>

        <Accordion type="single" collapsible className="w-full">
          {Array.from({ length: 8 }, (_, i) => (
            <AccordionItem key={i} value={`q${i}`}>
              <AccordionTrigger>How does billing work for plan number {i + 1}?</AccordionTrigger>
              <AccordionContent>
                Each seat is billed monthly from the day it is added. Removing a seat credits the rest of the month to
                the next invoice. Annual plans are billed once a year with the same rules.
              </AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>

        <section className="space-y-2">
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-semibold">Invoices</h2>
            <Dialog>
              <DialogTrigger asChild>
                <Button size="sm"><PlusIcon /> New</Button>
              </DialogTrigger>
              <DialogContent>
                <DialogHeader>
                  <DialogTitle>New invoice</DialogTitle>
                  <DialogDescription>A dialog: centred, over everything.</DialogDescription>
                </DialogHeader>
                <Input placeholder="Customer" />
                <DialogFooter><Button onClick={() => toast.success('Invoice created')}>Create</Button></DialogFooter>
              </DialogContent>
            </Dialog>
          </div>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Invoice</TableHead>
                <TableHead>Customer</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Method</TableHead>
                <TableHead className="text-right">Amount</TableHead>
                <TableHead className="text-right">Action</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {Array.from({ length: 10 }, (_, i) => (
                <TableRow key={i}>
                  <TableCell className="font-medium">INV-{1001 + i}</TableCell>
                  <TableCell>Customer {i + 1}</TableCell>
                  <TableCell>{i % 3 ? 'Paid' : 'Pending'}</TableCell>
                  <TableCell>Credit card</TableCell>
                  <TableCell className="text-right">${(120 + i * 37).toFixed(2)}</TableCell>
                  <TableCell className="text-right">
                    <Button variant="outline" size="sm" onClick={() => toast(`Opened INV-${1001 + i}`)}>Open</Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </section>

        <section className="space-y-3 pb-16">
          <h2 className="text-lg font-semibold">About this page</h2>
          {Array.from({ length: 6 }, (_, i) => (
            <p key={i}>
              Radix keeps focus, keyboard and screen reader behaviour inside each primitive, and shadcn/ui draws them
              with Tailwind. Popovers, menus and tooltips are placed by Floating UI in a portal at the end of the
              body, so they are fixed boxes outside the page's flow, measured from their trigger.
            </p>
          ))}
        </section>
      </main>
    </div>
  )
}
