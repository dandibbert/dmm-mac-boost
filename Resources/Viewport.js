(() => {
  const candidates = Array.from(document.querySelectorAll('canvas, iframe'))
    .map(element => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return { x: rect.x, y: rect.y, width: rect.width, height: rect.height,
        visible: style.display !== 'none' && style.visibility !== 'hidden',
        canvas: element.tagName === 'CANVAS' };
    })
    .filter(item => item.visible && item.width >= 320 && item.height >= 180
      && item.width / item.height >= 0.65 && item.width / item.height <= 3.2)
    .sort((a, b) => b.width * b.height - a.width * a.height);
  const best = candidates[0];
  if (!best) return null;
  if (candidates[1] && candidates[1].width * candidates[1].height > best.width * best.height * 0.92) return null;
  return { x: best.x, y: best.y, width: best.width, height: best.height,
    viewportWidth: innerWidth, viewportHeight: innerHeight };
})();
