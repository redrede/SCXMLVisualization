force = window.forceLayout = {}

KIELER_URL = 'http://kieler.herokuapp.com/live'
MARGIN = 5
ROUND_CORNER = 5
CELL_MIN = {w: 40, h: 40}
CELL_PAD = {top: 20, bottom: 5, left: 5, right: 5}
LABEL_SPACE = 400
CONTROL_SIZE = {w: 25, h: 25}
LINK_STRENGTH = .1
LINK_DISTANCE = 30
DEBUG_FORCE_FACTOR = 50
MIN_ZOOM = 1/6
MAX_ZOOM = 6
ANIMATION_SPEED = 2


strip = (obj) ->
  for key, value of obj
    if value?
      if _.isArray(value) and value.length == 0
        delete obj[key]
      else if _.isObject(value)
        strip(value)
        if _.isEmpty(value)
          delete obj[key]
    else
      delete obj[key]
  return obj


treeFromXml = (doc) ->
  parseActions = (container) ->
    rv = []
    for child in container.childNodes
      if child.tagName
        rv.push(xml: '' + child)
    return rv

  parseChildNodes = (node) ->
    transitions = []
    onentry = []
    onexit = []

    for child in node.childNodes
      switch child.tagName
        when 'transition'
          target = child.getAttribute('target')
          if target and target.indexOf(' ') > -1
            throw new Error("not implemented: transition with multiple targets")
          unless target
            target = node.getAttribute('id')
          transitions.push(strip(
            target: target
            cond: child.getAttribute('cond') or null
            event: child.getAttribute('event') or null
            actions: parseActions(child)
          ))

        when 'onentry'
          onentry = onentry.concat(parseActions(child))

        when 'onexit'
          onexit = onexit.concat(parseActions(child))

    return {
      transitions: transitions
      onentry: onentry
      onexit: onexit
    }

  parseStates = (node) ->
    stateList = []
    for node in node.childNodes
      state = switch node.tagName
        when 'initial'
          {
            type: 'initial'
            id: node.getAttribute('id') or null
            children: parseStates(node)
          }

        when 'state'
          {
            type: 'state'
            id: node.getAttribute('id') or null
            children: parseStates(node)
          }

        when 'final'
          {
            type: 'final'
            id: node.getAttribute('id') or null
            children: parseStates(node)
          }

        when 'parallel'
          {
            type: 'parallel'
            id: node.getAttribute('id') or null
            children: parseStates(node)
          }

        when 'history'
          {
            type: 'history'
            id: node.getAttribute('id') or null
            deep: node.getAttribute('type') == 'deep' or null
          }

      if state?
        _.extend(state, parseChildNodes(node))
        stateList.push(strip(state))

    return stateList

  return {sc: parseStates(doc.documentElement)}


idMaker = ->
  counterMap = d3.map()
  return (prefix='_force_id_') ->
    counter = counterMap.get(prefix) or 0
    counter += 1
    counterMap.set(prefix, counter)
    return "#{prefix}#{counter}"


nextId = idMaker()


def = (map, key, defaultValue) ->
  unless map.has(key)
    map.set(key, defaultValue)
  return map.get(key)


walk = (node, callback, parent=null, postorder=false) ->
  callback(node, parent) unless postorder
  for child in node.children or []
    walk(child, callback, node, postorder)
  callback(node, parent) if postorder


parents = (node) ->
  if node.parent then parents(node.parent).concat([node.parent]) else []


path = (node1, node2) ->
  parents1 = parents(node1)
  parents2 = parents(node2)
  eq = 0
  for n in [0 .. d3.min([parents1.length, parents2.length]) - 1]
    if parents1[n] != parents2[n] then break
    eq = n
  return [node1, parents1[eq], node2]


exit = (cell, point) ->
  d = {x: point.x - cell.x, y: point.y - cell.y}
  ex = cell.w / 2 / d.x
  ey = cell.h / 2 / d.y
  e = d3.min([ex, ey], Math.abs)
  return {x: cell.x + d.x * e, y: cell.y + d.y * e}


midpoint = (a, b) -> {
  x: ((a.x or 0) + (b.x or 0)) / 2
  y: ((a.y or 0) + (b.y or 0)) / 2
}


transitionPath = (tr) ->
  [a, b, c] = [tr.a, tr.b, tr]

  if tr.selfie
    w = c.x - a.x
    h = c.y - a.y
    c1 = {x: c.x - h/4, y: c.y + w/4}
    c2 = {x: c.x + h/4, y: c.y - w/4}
    s = exit(a, c1)
    t = exit(a, c2)
    return "M#{s.x},#{s.y}
            C#{c1.x},#{c1.y}
             #{c1.x},#{c1.y}
             #{c.x},#{c.y}
            C#{c2.x},#{c2.y}
             #{c2.x},#{c2.y}
             #{t.x},#{t.y}"

  else
    s = exit(a, c)
    t = exit(b, c)
    m = midpoint(c, midpoint(s, t))
    d = {x: c.x - m.x, y: c.y - m.y}
    sm = midpoint(s, m)
    tm = midpoint(t, m)
    i = sc = {x: sm.x + d.x, y: sm.y + d.y}
    j = tc = {x: tm.x + d.x, y: tm.y + d.y}
    return "M#{s.x},#{s.y}
            S#{i.x},#{i.y}
             #{c.x},#{c.y}
            S#{j.x},#{j.y}
             #{t.x},#{t.y}"


findTransition = (transitions, source, target) ->
  for tr in transitions
    if tr.a.id == source and tr.b.id == target
      return tr


toKielerFormat = (node) ->
  children = []
  edges = []
  for child in node.children or []
    children.push(toKielerFormat(child))
    for transition in child.transitions or []
      children.push(
        id: transition.id
        desmTransition: true
        width: transition.textWidth
        height: 25
      )
      edges.push(
        id: "#{transition.id}#1"
        source: child.id
        target: transition.id
      )
      edges.push(
        id: "#{transition.id}#2"
        source: transition.id
        target: transition.target
      )
  rv = {
    id: node.id
    children: children
    edges: edges
  }
  if node.id?
    rv.labels = [{text: node.id}]
  if (node.children or []).length == 0
    rv.width = node.w
    rv.height = node.h
  return rv


force.kielerLayout = (kielerAlgorithm, top) ->
  kNodeMap = d3.map()
  kEdgeMap = d3.map()

  applyLayout = (node, kNode, x0 = null, y0 = null) ->
    node.w = kNode.width
    node.h = kNode.height

    unless x0? and y0?
      x0 = -node.w/2
      y0 = -node.h/2

    node.x = x0 + (kNode.x or 0) + node.w/2
    node.y = y0 + (kNode.y or 0) + node.h/2

    for tr in node.transitions or []
      kTr = kNodeMap.get(tr.id)
      tr.x = x0 + kTr.x + kTr.width/2
      tr.y = y0 + kTr.y + kTr.height/2 - 10

      e1 = kEdgeMap.get("#{tr.id}#1")
      e2 = kEdgeMap.get("#{tr.id}#2")
      tr.route = [].concat(
        [e1.sourcePoint]
        e1.bendPoints or []
        [e1.targetPoint]
        [e2.sourcePoint]
        e2.bendPoints or []
        [e2.targetPoint]
      ).map((d) -> [x0 + d.x, y0 + d.y])

    childMap = d3.map()
    for child in node.children or []
      if child.id? then childMap.set(child.id, child)

    for kChild in kNode.children or []
      unless (child = childMap.get(kChild.id))? then continue
      unless kChild.desmTransition
        applyLayout(child, kChild, node.x - node.w/2, node.y - node.h/2)

  graph = toKielerFormat(top)

  if kielerAlgorithm == '__klayjs'
    klay_ready = Q.defer()
    $klay.layout(
      graph: graph
      options:
        layoutHierarchy: true
        edgeRouting: 'ORTHOGONAL'
      success: klay_ready.resolve
      error: (err) -> klay_ready.reject(new Error(err.text))
    )

    layoutDone = klay_ready.promise

  else
    form = {
      graph: JSON.stringify(graph)
      config: JSON.stringify(
        algorithm: kielerAlgorithm
        edgeRouting: 'ORTHOGONAL'
        layoutHierarchy: true
      )
      iFormat: 'org.json'
      oFormat: 'org.json'
    }

    layoutDone = Q($.post(KIELER_URL, form))
      .catch (resp) ->
        throw Error(resp.responseText)
      .then (resp) ->
        return JSON.parse(resp)[0]

  return layoutDone
    .then (graphLayout) ->
      walk graphLayout, (kNode) =>
        kNodeMap.set(kNode.id, kNode)
        for kEdge in kNode.edges or []
          kEdgeMap.set(kEdge.id, kEdge)
      applyLayout(top, graphLayout)


class NewNodesAnimation

  constructor: (@newNodes) ->
    @deferred = Q.defer()
    @promise = @deferred.promise
    @done = no
    @targetMap = d3.map()
    @abort() unless @newNodes.length > 0

    for node in @newNodes
      @targetMap.set(node.id, {w: node.w, h: node.h})
      node.w = node.h = 5

  tick: ->
    return if @done
    changed = no
    for node in @newNodes
      target = @targetMap.get(node.id)
      (node.w += ANIMATION_SPEED; changed = yes) if node.w < target.w
      (node.h += ANIMATION_SPEED; changed = yes) if node.h < target.h

    @abort() unless changed

  abort: ->
    @done = yes
    @deferred.resolve()


class LoadingOverlay

  constructor: (options) ->
    w = $(options.svg).width()
    h = $(options.svg).height()
    @el = d3.select(options.svg).append('g')
        .attr('class', "loadingOverlay")
    @el.append('rect')
        .attr('width', w)
        .attr('height', h)
    @el.append('text')
        .attr('x', w/2)
        .attr('y', h/2)
        .text(options.text)

  destroy: ->
    @el.remove()


class force.Layout

  constructor: (options) ->
    @id = nextId()
    @queue = async.queue(((task, cb) -> task(cb)), 1)
    @options = options
    @debug = options.debug or false
    @svgCreate(options.parent)
    @runSimulation = false
    @s = @_emptyState()
    @animation = new NewNodesAnimation([])
    @_initialTree(options.tree or treeFromXml(options.doc).sc)

  _initialTree: (tree) ->
    deferred = Q.defer()
    @initialized = deferred.promise

    @queue.push (cb) =>
      @loadTree(tree)

      if @options.geometry?
        @applyGeometry(@options.geometry)
        @beginSimulation()
        cb()
        deferred.resolve()

      else
        loading = new LoadingOverlay(svg: @el, text: "Loading Kieler layout ...")
        deferred.resolve(
          force.kielerLayout(@options.kielerAlgorithm, @s.top)
            .then (treeWithLayout) =>
              loading.destroy()
              @beginSimulation()
              cb()
        )

  update: (doc) ->
    deferred = Q.defer()
    @queue.push (cb) =>
      deferred.resolve(
        Q()
        .then =>
          @loadTree(treeFromXml(doc).sc)
        .then =>
          @beginSimulation()
          @s.newNodes = [] unless @runSimulation
        .then =>
          @animation = new NewNodesAnimation(@s.newNodes)
          return @animation.promise
        .catch (e) =>
          console.error e
        .finally =>
          cb()
      )

    return deferred.promise

  _emptyState: -> {
      nodes: []
      cells: []
      nodeMap: d3.map()
      links: []
      transitions: []
      top: {
        children: []
        controls: []
      }
      newNodes: []
      dom: d3.map()
    }

  loadTree: (tree) ->
    @mergeTree(tree)
    @svgNodes()

  beginSimulation: ->
    @setupD3Layout()
    @layout.on 'tick', =>
      @adjustLayout()
      @svgUpdate()
      @animation.tick()
    @svgUpdate()

  mergeTree: (tree) ->
    oldS = @s
    newS = @_emptyState()
    newS.top.children = tree

    makeId = idMaker()

    for topNode in tree
      walk topNode, (node, parent) =>
        if node.id
          node.label = node.id
        else
          node.id = makeId("_node_")
          node.label = "<#{node.type}>"
        node.controls = []
        node.children = node.children or []
        if (oldNode = oldS.nodeMap.get(node.id))?
          node.x = oldNode.x
          node.y = oldNode.y
          node.w = oldNode.w
          node.h = oldNode.h
        else
          node.w = CELL_MIN.w
          node.h = CELL_MIN.h
          if parent?
            node.x = parent.x
            node.y = parent.y
          newS.newNodes.push(node)
        newS.nodes.push(node)
        newS.cells.push(node)
        newS.nodeMap.set(node.id, node)
        node.parent = if parent? then newS.nodeMap.get(parent.id) else newS.top

    for topNode in tree
      walk topNode, (node) =>
        for tr in node.transitions or []
          unless (target = newS.nodeMap.get(tr.target))?
            throw Error("missing transition target: #{tr.target}")
          [a, c, b] = path(node, target)
          tr.parent = c or newS.top
          tr.w = CONTROL_SIZE.w
          tr.h = CONTROL_SIZE.h
          tr.id = tr.id or makeId("_transition/#{node.id}/#{target.id}/")
          newS.nodeMap.set(tr.id, tr)
          tr.parent.controls.push(tr)
          newS.nodes.push(tr)
          for [link_source, link_target] in d3.pairs([a, tr, b])
            newS.links.push(
              source: link_source
              target: link_target
            )
          label = tr.event or ''
          tr.a = a
          tr.b = b
          tr.selfie = node.id == tr.target
          tr.label = label
          newS.transitions.push(tr)
          if (oldTr = findTransition(oldS.transitions, tr.a.id, tr.b.id))?
            _.extend(tr, {x: oldTr.x, y: oldTr.y})
          else
            _.extend(tr, midpoint(tr.a, tr.b))

    @layout.stop() if @layout
    @s = newS

  saveGeometry: ->
    round = (x) -> Math.round(x)
    return JSON.stringify({
      nodes: {
        id: n.id
        w: round(n.w)
        h: round(n.h)
        x: round(n.x)
        y: round(n.y)
      } for n in @s.nodes
    })

  applyGeometry: (geom) ->
    for saved in JSON.parse(geom).nodes
      if (node = @s.nodeMap.get(saved.id))?
        node.w = saved.w
        node.h = saved.h
        node.px = node.x = saved.x
        node.py = node.y = saved.y
    @svgUpdate()
    @layout.start() if @layout and @runSimulation

  svgCreate: (parent) ->
    @zoomBehavior = d3.behavior.zoom()
        .scaleExtent([MIN_ZOOM, MAX_ZOOM])

    svg = d3.select(parent).append('svg')
        .attr('xmlns:xmlns:xlink', 'http://www.w3.org/1999/xlink')
        .classed('force-layout', true)
        .classed('debug', @debug)
    @el = svg[0][0]
    defs = svg.append('defs')
    @zoomNode = svg.append('g').call(@zoomBehavior)
    @container = @zoomNode.append('g')

    @container.append('rect')
        .attr('class', 'zoomRect')

    @zoomBehavior.on 'zoom', =>
        e = d3.event
        @container.attr('transform', "translate(#{e.translate}),scale(#{e.scale})")

    defs.append('marker')
        .attr('id', "#{@id}-arrow")
        .attr('refX', '7')
        .attr('refY', '5')
        .attr('markerWidth', '10')
        .attr('markerHeight', '10')
        .attr('orient', 'auto')
      .append('path')
        .attr('d', 'M 0 0 L 10 5 L 0 10 z')
        .attr('class', 'arrow')

    @invalidateSize()

  invalidateSize: ->
    $parent = $(@el).parent()
    width = $parent.width() - 5
    height = $parent.height() - 5

    d3.select(@el)
        .attr('width', width)
        .attr('height', height)

    @container.select('.zoomRect')
        .attr('width', width / MIN_ZOOM)
        .attr('height', height / MIN_ZOOM)
        .attr('x', - width / 2 / MIN_ZOOM)
        .attr('y', - height / 2 / MIN_ZOOM)

    @zoomBehavior
        .size([width, height])
        .translate([width / 2, height / 2])

    @zoomBehavior.event(@zoomNode)

  svgNodes: ->
    @container.selectAll('.cell').remove()
    @container.selectAll('.transition').remove()
    @container.selectAll('.transition-label').remove()

    cell = @container.selectAll('.cell')
        .data(@s.cells)
      .enter().append('g')
        .attr('class', (cell) -> "cell cell-#{cell.type or 'state'} draggable")
        .classed('parallel-child', (cell) -> cell.parent.type == 'parallel')

    cell.append('rect')
        .attr('class', 'border')
        .attr('rx', ROUND_CORNER)
        .attr('ry', ROUND_CORNER)

    cell.append('text')
        .text((node) -> node.label)
        .each (node) ->
          node.textWidth = d3.min([$(@).width() + 2 * ROUND_CORNER, LABEL_SPACE])
          node.w = d3.max([node.w, node.textWidth])

    @container.selectAll('.transition')
        .data(@s.transitions)
      .enter().append('g')
        .attr('class', 'transition')
      .append('path')
        .attr('style', "marker-end: url(##{@id}-arrow)")
        .attr('id', (tr) => "#{@id}-transition/#{tr.id}")

    transitionLabel = @container.selectAll('.transition-label')
        .data(@s.transitions)
      .enter().append('g')
        .attr('class', 'transition-label draggable')

    if @options.textOnPath
      transitionLabel.append('text')
        .append('textPath')
          .attr('xlink:href', (tr) => "##{@id}-transition/#{tr.id}")
          .attr('startOffset', '50%')
          .text((tr) -> tr.label)

    else
      transitionLabel.append('text')
        .text((tr) -> tr.label)
        .each (tr) ->
          tr.textWidth = d3.min([$(@).width() + 5, LABEL_SPACE])
          tr.w = d3.max([tr.w, tr.textWidth])
        .attr('dy', '.3em')

      transitionLabel.append('rect')
          .attr('x', (tr) -> -tr.w / 2)
          .attr('y', (tr) -> -tr.h / 2)
          .attr('width', (tr) -> tr.w)
          .attr('height', (tr) -> tr.h)

    dom = @s.dom

    @container.selectAll('.cell')
        .each (node) ->
          dom.set("cell-#{node.id}", @)

    @container.selectAll('.transition')
        .each (node) ->
          dom.set("transition-#{node.id}", @)

  svgUpdate: ->
    @container.selectAll('.cell')
        .attr('transform', (node) -> "translate(#{node.x},#{node.y})")
        .classed('fixed', (node) -> node.fixed)

    @container.selectAll('.cell').each (node) ->
        d3.select(this).select('rect')
            .attr('x', - node.w / 2)
            .attr('y', - node.h / 2)
            .attr('width', node.w)
            .attr('height', node.h)

        d3.select(this).select('text')
            .attr('y', (node) -> CELL_PAD.top - node.h / 2 - 5)

    @container.selectAll('.selfie').remove()

    @container.selectAll('.transition').selectAll('path')
        .attr 'd', (tr) ->
          if tr.route? then d3.svg.line()(tr.route) else transitionPath(tr)

    unless @options.textOnPath
      @container.selectAll('.transition-label')
          .attr('transform', (tr) -> "translate(#{tr.x},#{tr.y})")

  setupD3Layout: ->
    @layout = d3.layout.force()
        .charge(0)
        .gravity(0)
        .linkStrength(LINK_STRENGTH)
        .linkDistance(LINK_DISTANCE)
        .nodes(@s.nodes)
        .links(@s.links)
        .start()

    @layout.stop() unless @runSimulation

    lock = {node: null, drag: false}

    drag = d3.behavior.drag()
        .origin((node) -> node)
        .on 'dragstart', (node) =>
          d3.event.sourceEvent.stopPropagation()
          (lock.node = node).fixed = true
          lock.drag = true
        .on 'drag', (node) =>
          d3.event.sourceEvent.stopPropagation()
          node.px = d3.event.x
          node.py = d3.event.y
          if @runSimulation
            @layout.resume()
          else
            node.x = node.px
            node.y = node.py
            @adjustLayout()
            @svgUpdate()
        .on 'dragend', (node) =>
          d3.event.sourceEvent.stopPropagation()
          lock.drag = false
          lock.node = null
          node.fixed = false

    @container.selectAll('.draggable')
        .on 'mouseover', (node) =>
          if lock.drag then return
          if lock.node then lock.node.fixed = false
          (lock.node = node).fixed = true
          node.px = node.x
          node.py = node.y
          @svgUpdate()
        .on 'mouseout', (node) =>
          if lock.drag then return
          lock.node = null
          node.fixed = false
          @svgUpdate()
        .call(drag)

  adjustLayout: ->
    tick = {
      gravity: @layout.alpha() * 0.1
      forces: d3.map()
    }

    move = (node, dx, dy) ->
      node.x += dx
      node.y += dy
      for child in node.children or []
        move(child, dx, dy)
      for control in node.controls or []
        move(control, dx, dy)


    handleCollisions = (parent, center, tick) =>
      for child in parent.children
        dx = (center.x - child.x) * tick.gravity
        dy = (center.y - child.y) * tick.gravity
        move(child, dx, dy)
        def(tick.forces, child.id, []).push(value: [dx, dy], cls: 'gravity')

      objects = [].concat(parent.children, parent.controls)
      q = d3.geom.quadtree(objects)

      for node in objects
        nx1 = node.x - node.w - 100
        nx2 = node.x + node.w + 100
        ny1 = node.y - node.h - 100
        ny2 = node.y + node.h + 100

        collide = (quad, x1, y1, x2, y2) =>
          other = quad.point
          if other and (other != node)
            dx = node.x - other.x
            dy = node.y - other.y
            w = (node.w + other.w) / 2 + MARGIN
            h = (node.h + other.h) / 2 + MARGIN

            cx = w - Math.abs(dx)
            cy = h - Math.abs(dy)
            if cx > 0 and cy > 0
              na = node.w * node.h
              oa = other.w * other.h
              f = oa / (oa + na)

              if cx/w < cy/h
                dy1 = dy2 = 0
                s = if dx > 0 then 1 else -1
                dx1 = s * f * cx
                dx2 = s * (f-1) * cx

              else
                dx1 = dx2 = 0
                s = if dy > 0 then 1 else -1
                dy1 = s * f * cy
                dy2 = s * (f-1) * cy

              move(node, dx1, dy1)
              move(other, dx2, dy2)
              def(tick.forces, node.id, []).push(value: [dx1, dy1], cls: 'collision')
              def(tick.forces, other.id, []).push(value: [dx2, dy2], cls: 'collision')

          return x1 > nx2 or x2 < nx1 or y1 > ny2 or y2 < ny1

        q.visit(collide)


    adjustNode = (node) =>
      if node.children.length > 0
        handleCollisions(node, node, tick)

        contents = [].concat(node.children, node.controls)
        xMin = d3.min(contents, (d) -> d.x - d.w / 2) - CELL_PAD.left
        xMax = d3.max(contents, (d) -> d.x + d.w / 2) + CELL_PAD.right
        yMin = d3.min(contents, (d) -> d.y - d.h / 2) - CELL_PAD.top
        yMax = d3.max(contents, (d) -> d.y + d.h / 2) + CELL_PAD.bottom
        grow = node.textWidth - (xMax - xMin)
        if grow > 0
          xMin -= grow / 2
          xMax += grow / 2
        node.w = xMax - xMin
        node.h = yMax - yMin
        dx = xMin + node.w / 2 - node.x
        dy = yMin + node.h / 2 - node.y
        node.x += dx
        node.y += dy
        if node.fixed
          move(node, -dx, -dy)

      node.weight = node.w * node.h

    for node in @s.top.children
      walk(node, adjustNode, null, true)

    handleCollisions(@s.top, {x: 0, y: 0}, tick)

    for tr in @s.transitions
      delete tr.route

    if @debug
      @container.selectAll('.cell .force').remove()

      @container.selectAll('.cell')
          .each (node) ->
            for force in tick.forces.get(node.id) or []
              d3.select(@).append('line')
                  .attr('class', "force #{force.cls}")
                  .attr('x1', 0)
                  .attr('y1', 0)
                  .attr('x2', force.value[0] * DEBUG_FORCE_FACTOR)
                  .attr('y2', force.value[1] * DEBUG_FORCE_FACTOR)

  start: ->
    @runSimulation = true
    @layout.start() if @layout?

  stop: ->
    @runSimulation = false
    @layout.stop() if @layout?

  highlightState: (id, highlight=true) ->
    @queue.push (cb) =>
      d3.select(@s.dom.get("cell-#{id}"))
          .classed('highlight', highlight)
      cb()

  highlightTransition: (source, target, highlight=true) ->
    @queue.push (cb) =>
      if (tr = findTransition(@s.transitions, source, target))?
        d3.select(@s.dom.get("transition-#{tr.id}"))
            .classed('highlight', highlight)
      cb()


force.render = (options) ->
  return new force.Layout(options)
