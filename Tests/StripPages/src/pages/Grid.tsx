import { useEffect, useMemo, useRef, useState } from 'react'
import { AllCommunityModule, ModuleRegistry, themeQuartz, type ColDef, type ICellRendererParams } from 'ag-grid-community'
import { AgGridReact } from 'ag-grid-react'
import { DownloadIcon, PencilIcon } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

ModuleRegistry.registerModules([AllCommunityModule])

// AG Grid twice: one in the page's flow, as tall as its rows, scrolling
// sideways inside itself with its actions column pinned at the right edge;
// one that scrolls by itself, its rows drawn as they come into view, with
// paging at its foot. Prices change every second, as a ticker's do.

type Row = { id: number; name: string; email: string; role: string; status: string; price: number; updated: string }

const roles = ['Owner', 'Admin', 'Member', 'Guest']
const statuses = ['Active', 'Invited', 'Suspended']

function rows(count: number): Row[] {
  return Array.from({ length: count }, (_, i) => ({
    id: i + 1,
    name: `Person ${i + 1}`,
    email: `person${i + 1}@example.com`,
    role: roles[i % roles.length],
    status: statuses[i % statuses.length],
    price: 100 + ((i * 37) % 400),
    updated: `${(i % 59) + 1} minutes ago`,
  }))
}

function Actions(params: ICellRendererParams<Row>) {
  return (
    <div className="flex h-full items-center gap-1">
      <Button variant="ghost" size="icon" aria-label="Edit" onClick={() => toast(`Edit ${params.data?.name}`)}>
        <PencilIcon />
      </Button>
      <Button variant="outline" size="sm" onClick={() => toast(`Opened ${params.data?.name}`)}>Open</Button>
    </div>
  )
}

const columns: ColDef<Row>[] = [
  { field: 'name', minWidth: 140 },
  { field: 'email', minWidth: 220 },
  { field: 'role', minWidth: 110 },
  { field: 'status', minWidth: 110 },
  { field: 'price', minWidth: 110, type: 'rightAligned', cellClass: 'tabular-nums', valueFormatter: (p) => `$${p.value}` },
  { field: 'updated', minWidth: 150 },
  { headerName: 'Actions', pinned: 'right', width: 132, cellRenderer: Actions, sortable: false, filter: false },
]

function useTicker(start: Row[]) {
  const [data, setData] = useState(start)
  useEffect(() => {
    const timer = setInterval(() => {
      setData((old) => old.map((row, i) => (i % 3 === Math.floor(Date.now() / 1000) % 3
        ? { ...row, price: Math.max(1, row.price + Math.round(Math.random() * 20 - 10)) }
        : row)))
    }, 1000)
    return () => clearInterval(timer)
  }, [])
  return data
}

export default function Grid() {
  const flowRows = useTicker(useMemo(() => rows(30), []))
  const manyRows = useMemo(() => rows(2000), [])
  const [filter, setFilter] = useState('')
  const grid = useRef<AgGridReact<Row>>(null)
  const defaults = useMemo<ColDef>(() => ({ sortable: true, filter: true, resizable: true }), [])
  return (
    <div className="min-h-screen bg-background">
      <header className="flex items-center justify-between gap-2 border-b px-4 py-3">
        <a href="#/" className="font-semibold">People</a>
        <div className="flex items-center gap-2">
          <Input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder="Filter" className="h-8 w-32" />
          <Button size="sm" variant="outline" onClick={() => grid.current?.api.exportDataAsCsv()}>
            <DownloadIcon /> CSV
          </Button>
        </div>
      </header>
      <main className="space-y-6 px-4 py-4">
        <p className="text-sm text-muted-foreground">
          The grid below is as tall as its rows, so the page scrolls it; it scrolls sideways inside itself, its
          Actions column pinned at its right edge. Prices change every second.
        </p>
        <AgGridReact<Row>
          ref={grid}
          theme={themeQuartz}
          rowData={flowRows}
          columnDefs={columns}
          defaultColDef={defaults}
          domLayout="autoHeight"
          quickFilterText={filter}
          rowSelection={{ mode: 'multiRow' }}
          getRowId={(p) => String(p.data.id)}
        />
        <h2 className="text-lg font-semibold">Two thousand rows, scrolling by itself</h2>
        <div style={{ height: 420 }}>
          <AgGridReact<Row>
            theme={themeQuartz}
            rowData={manyRows}
            columnDefs={columns}
            defaultColDef={defaults}
            pagination
            paginationPageSize={100}
            paginationPageSizeSelector={[50, 100, 500]}
          />
        </div>
        <section className="space-y-3 pb-16">
          {Array.from({ length: 5 }, (_, i) => (
            <p key={i}>
              AG Grid draws only the rows and columns in view and moves them with transforms as it scrolls, so what
              is under the strip changes with every frame of a scroll inside the grid, while the page itself stands
              still.
            </p>
          ))}
        </section>
      </main>
    </div>
  )
}
