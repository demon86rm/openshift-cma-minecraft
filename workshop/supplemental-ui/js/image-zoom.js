// In-page zoom for linked images (image::...[link=...]): click opens an overlay,
// click on the image toggles fit / full size, Esc or click outside closes.
// Without JavaScript the link still opens the image on its own.
(function () {
  var style = document.createElement('style')
  style.textContent =
    'dialog.image-zoom{padding:0;border:0;max-width:96vw;max-height:96vh;overflow:auto;background:#fff}' +
    'dialog.image-zoom::backdrop{background:rgba(0,0,0,.75)}' +
    'dialog.image-zoom img{display:block;max-width:96vw;max-height:96vh;cursor:zoom-in}' +
    'dialog.image-zoom.full img{max-width:none;max-height:none;cursor:zoom-out}'
  document.head.appendChild(style)

  var dialog = document.createElement('dialog')
  dialog.className = 'image-zoom'
  var img = document.createElement('img')
  dialog.appendChild(img)
  document.body.appendChild(dialog)
  if (typeof dialog.showModal !== 'function') return // old browser: keep the plain link

  img.addEventListener('click', function () { dialog.classList.toggle('full') })
  // A click on the backdrop targets the dialog itself, not the image.
  dialog.addEventListener('click', function (e) { if (e.target === dialog) dialog.close() })
  dialog.addEventListener('close', function () { dialog.classList.remove('full') })

  document.querySelectorAll('.imageblock a[href]').forEach(function (a) {
    if (!/\.(png|jpe?g|gif|svg|webp)$/i.test(a.getAttribute('href'))) return
    a.addEventListener('click', function (e) {
      e.preventDefault()
      var thumb = a.querySelector('img')
      img.src = a.href
      img.alt = thumb ? thumb.alt : ''
      dialog.showModal()
    })
  })
})()
