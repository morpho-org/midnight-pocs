import {
  ConnectionMode,
  Handle,
  MarkerType,
  Position,
  ReactFlow,
  type Edge,
  type Node,
  type NodeProps,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'

type NodeData = { name: string; detail: string; active: boolean; kind: 'blue' | 'lender' | 'midnight' | 'borrower' }
type ProtocolNode = Node<NodeData, 'protocol'>
type Arrow = { from: number; to: number; gap: number; reverse: boolean; label: string }

const nodeTypes = { protocol: ProtocolNodeView }

export function ProtocolFlow({ arrow, drawPath, advance, general, liquidityName, lenderName, details }: {
  arrow: Arrow
  drawPath: boolean
  advance: string
  general: boolean
  liquidityName: string
  lenderName: string
  details: { blue: string; lender: string; borrower: string }
}) {
  const active = (id: number) => drawPath ? id > 0 : arrow.from === id || arrow.to === id
  const nodes: ProtocolNode[] = [
    protocolNode('blue', 45, 5, liquidityName, details.blue, active(0), 'blue'),
    protocolNode('lender', 25, 160, lenderName, details.lender, active(1), 'lender'),
    protocolNode('midnight', 455, 160, 'Midnight', 'Markets', active(2), 'midnight'),
    protocolNode('borrower', 805, 160, 'Borrower', details.borrower, active(3), 'borrower'),
  ]

  const gapActive = (gap: number) => arrow.gap === gap || drawPath && (gap === 1 || gap === 2)
  const edges: Edge[] = [
    general
      ? flowEdge('blue-midnight', 0, arrow, 'blue', 'midnight', 'right', 'left', gapActive(0), arrow.label)
      : flowEdge('blue-lender', 0, arrow, 'blue', 'lender', 'bottom', 'top', gapActive(0), arrow.label),
    flowEdge('lender-midnight', 1, arrow, 'lender', 'midnight', 'right', 'left', gapActive(1), drawPath ? advance : arrow.label),
    flowEdge('midnight-borrower', 2, arrow, 'midnight', 'borrower', 'right', 'left', gapActive(2), drawPath ? 'Proceeds' : arrow.label),
  ]

  return (
    <div className="react-flow-map">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        connectionMode={ConnectionMode.Loose}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        panOnDrag={false}
        zoomOnScroll={false}
        zoomOnPinch={false}
        zoomOnDoubleClick={false}
        preventScrolling={false}
        fitView
        fitViewOptions={{ padding: 0.08 }}
        proOptions={{ hideAttribution: true }}
      />
    </div>
  )
}

function protocolNode(id: string, x: number, y: number, name: string, detail: string, active: boolean, kind: NodeData['kind']): ProtocolNode {
  return { id, type: 'protocol', position: { x, y }, data: { name, detail, active, kind }, draggable: false, selectable: false }
}

function flowEdge(
  id: string,
  gap: number,
  arrow: Arrow,
  defaultSource: string,
  defaultTarget: string,
  defaultSourceHandle: string,
  defaultTargetHandle: string,
  active: boolean,
  label: string,
): Edge {
  const reverse = active && arrow.gap === gap && arrow.reverse
  const source = reverse ? defaultTarget : defaultSource
  const target = reverse ? defaultSource : defaultTarget
  const sourceHandle = reverse ? defaultTargetHandle : defaultSourceHandle
  const targetHandle = reverse ? defaultSourceHandle : defaultTargetHandle
  const color = active ? '#5792ff' : '#596273'
  return {
    id,
    source,
    target,
    sourceHandle,
    targetHandle,
    type: gap === 0 ? 'smoothstep' : 'straight',
    animated: active,
    label: active ? label : undefined,
    markerEnd: { type: MarkerType.ArrowClosed, color, width: active ? 18 : 14, height: active ? 18 : 14 },
    style: { stroke: color, strokeWidth: active ? 2 : 1.2 },
    labelStyle: { fill: active ? '#8ab2ff' : '#95a1b8', fontSize: 10, fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' },
    labelBgStyle: { fill: '#15181a', fillOpacity: 1 },
    labelBgPadding: [7, 4],
    labelBgBorderRadius: 4,
    selectable: false,
    focusable: false,
    zIndex: active ? 2 : 1,
  }
}

function ProtocolNodeView({ data }: NodeProps<ProtocolNode>) {
  return (
    <div className={`flow-node flow-node-${data.kind} ${data.active ? 'active' : ''}`}>
      {data.kind === 'blue' && <><Handle id="bottom" type="source" position={Position.Bottom} /><Handle id="right" type="source" position={Position.Right} /></>}
      {data.kind === 'lender' && <><Handle id="top" type="source" position={Position.Top} /><Handle id="right" type="source" position={Position.Right} /></>}
      {data.kind === 'midnight' && <><Handle id="left" type="source" position={Position.Left} /><Handle id="right" type="source" position={Position.Right} /></>}
      {data.kind === 'borrower' && <Handle id="left" type="source" position={Position.Left} />}
      <strong>{data.name}</strong>
      <span>{data.detail}</span>
    </div>
  )
}
