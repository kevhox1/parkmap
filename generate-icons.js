const { createCanvas } = require('canvas');
const fs = require('fs');
const path = require('path');

function generateIcon(size, outputPath) {
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');

  // Blue background with rounded corners effect
  ctx.fillStyle = '#2563eb';
  const r = size * 0.15;
  ctx.beginPath();
  ctx.moveTo(r, 0);
  ctx.lineTo(size - r, 0);
  ctx.quadraticCurveTo(size, 0, size, r);
  ctx.lineTo(size, size - r);
  ctx.quadraticCurveTo(size, size, size - r, size);
  ctx.lineTo(r, size);
  ctx.quadraticCurveTo(0, size, 0, size - r);
  ctx.lineTo(0, r);
  ctx.quadraticCurveTo(0, 0, r, 0);
  ctx.closePath();
  ctx.fill();

  // White "P" letter
  ctx.fillStyle = '#ffffff';
  ctx.font = `bold ${size * 0.6}px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('P', size / 2, size / 2 + size * 0.02);

  // Small parking icon indicator (circle) at bottom right
  const indicatorR = size * 0.12;
  ctx.fillStyle = '#22c55e';
  ctx.beginPath();
  ctx.arc(size * 0.78, size * 0.78, indicatorR, 0, Math.PI * 2);
  ctx.fill();

  // Write to file
  const buffer = canvas.toBuffer('image/png');
  fs.writeFileSync(outputPath, buffer);
  console.log(`Generated ${outputPath} (${size}x${size}, ${buffer.length} bytes)`);
}

const dir = path.dirname(__filename);
generateIcon(192, path.join(dir, 'icon-192.png'));
generateIcon(512, path.join(dir, 'icon-512.png'));
