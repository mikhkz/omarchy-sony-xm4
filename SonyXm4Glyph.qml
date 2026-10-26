import QtQuick

// A theme-aware, resolution-independent WH-1000XM4 silhouette.  Canvas keeps
// the asset native to QML: there is no bitmap to blur on a scaled display and
// no icon font whose shape depends on what happens to be installed.
Item {
  id: root

  property color tint: "white"
  property color accent: tint
  property string mode: "off"

  implicitWidth: 48
  implicitHeight: 48

  readonly property color quietTint: Qt.rgba(tint.r, tint.g, tint.b, 0.42)
  readonly property color modeTint: mode === "off" ? quietTint : accent

  onTintChanged: drawing.requestPaint()
  onAccentChanged: drawing.requestPaint()
  onModeChanged: drawing.requestPaint()

  Canvas {
    id: drawing
    anchors.fill: parent
    antialiasing: true

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      ctx.save()
      ctx.scale(width / 100, height / 100)
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      // The XM4 headband is broad at the crown and narrows into the sliders.
      // Two arcs give it the characteristic padded, layered construction.
      ctx.strokeStyle = root.tint
      ctx.lineWidth = 6.0
      ctx.beginPath()
      ctx.moveTo(23, 55)
      ctx.bezierCurveTo(23, 27, 33, 10, 50, 10)
      ctx.bezierCurveTo(67, 10, 77, 27, 77, 55)
      ctx.stroke()

      ctx.strokeStyle = root.quietTint
      ctx.lineWidth = 2.4
      ctx.beginPath()
      ctx.moveTo(31, 51)
      ctx.bezierCurveTo(31, 31, 38, 20, 50, 20)
      ctx.bezierCurveTo(62, 20, 69, 31, 69, 51)
      ctx.stroke()

      // Slim telescopic arms and the small round XM4 swivel joints.
      ctx.strokeStyle = root.tint
      ctx.lineWidth = 3.8
      ctx.beginPath()
      ctx.moveTo(24, 48); ctx.lineTo(21, 64)
      ctx.moveTo(76, 48); ctx.lineTo(79, 64)
      ctx.stroke()

      ctx.fillStyle = root.modeTint
      ctx.beginPath(); ctx.arc(21, 64, 4.2, 0, Math.PI * 2); ctx.fill()
      ctx.beginPath(); ctx.arc(79, 64, 4.2, 0, Math.PI * 2); ctx.fill()

      // Tall, softly asymmetric oval cups.  The outer shell is solid enough to
      // read at panel size; the inset line suggests the deep memory-foam pad.
      ctx.fillStyle = root.tint
      ctx.beginPath()
      ctx.moveTo(18, 56)
      ctx.bezierCurveTo(9, 59, 8, 68, 10, 80)
      ctx.bezierCurveTo(12, 93, 20, 98, 28, 92)
      ctx.bezierCurveTo(35, 87, 35, 65, 29, 59)
      ctx.bezierCurveTo(26, 57, 22, 56, 19, 57)
      ctx.fill()

      ctx.beginPath()
      ctx.moveTo(82, 56)
      ctx.bezierCurveTo(91, 59, 92, 68, 90, 80)
      ctx.bezierCurveTo(88, 93, 80, 98, 72, 92)
      ctx.bezierCurveTo(65, 87, 65, 65, 71, 59)
      ctx.bezierCurveTo(74, 57, 78, 56, 81, 57)
      ctx.fill()

      ctx.strokeStyle = root.quietTint
      ctx.lineWidth = 2.2
      ctx.beginPath()
      ctx.moveTo(19, 64)
      ctx.bezierCurveTo(15, 69, 16, 84, 21, 88)
      ctx.bezierCurveTo(25, 90, 28, 82, 28, 72)
      ctx.bezierCurveTo(28, 66, 24, 62, 19, 64)
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(81, 64)
      ctx.bezierCurveTo(85, 69, 84, 84, 79, 88)
      ctx.bezierCurveTo(75, 90, 72, 82, 72, 72)
      ctx.bezierCurveTo(72, 66, 76, 62, 81, 64)
      ctx.stroke()

      // A restrained mode cue lives between the cups: muted when processing is
      // off, accented while ANC, wind reduction, or ambient sound is active.
      ctx.strokeStyle = root.modeTint
      ctx.lineWidth = 2.6
      ctx.beginPath()
      if (root.mode === "ambient") {
        ctx.arc(50, 73, 7, -0.8, 0.8)
        ctx.moveTo(57, 64); ctx.arc(50, 73, 11, -0.8, 0.8)
      } else if (root.mode === "wind") {
        ctx.moveTo(40, 69); ctx.bezierCurveTo(45, 65, 51, 65, 57, 69)
        ctx.moveTo(43, 76); ctx.bezierCurveTo(48, 72, 54, 72, 60, 76)
      } else if (root.mode === "anc") {
        ctx.moveTo(42, 68); ctx.lineTo(47, 73); ctx.lineTo(42, 78)
        ctx.moveTo(58, 68); ctx.lineTo(53, 73); ctx.lineTo(58, 78)
      } else {
        ctx.arc(50, 73, 5, -Math.PI * 0.35, Math.PI * 1.35)
        ctx.moveTo(50, 65); ctx.lineTo(50, 71)
      }
      ctx.stroke()
      ctx.restore()
    }
  }
}
