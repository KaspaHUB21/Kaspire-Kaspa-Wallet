"use client";

import { useEffect, useRef } from "react";

type Point = {
  x: number;
  y: number;
  vx: number;
  vy: number;
  phase: number;
};

export default function DagField() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const context = canvas.getContext("2d");
    if (!context) return;
    let frame = 0;
    let width = 0;
    let height = 0;
    let points: Point[] = [];

    const resize = () => {
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = canvas.clientWidth;
      height = canvas.clientHeight;
      canvas.width = width * ratio;
      canvas.height = height * ratio;
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      const count = Math.max(20, Math.min(46, Math.round(width / 34)));
      points = Array.from({ length: count }, (_, index) => ({
        x: ((index * 83) % Math.max(width, 1)) + Math.random() * 35,
        y: 70 + Math.random() * Math.max(height - 140, 1),
        vx: (Math.random() - 0.5) * 0.08,
        vy: (Math.random() - 0.5) * 0.04,
        phase: Math.random() * Math.PI * 2,
      }));
    };

    const render = (time: number) => {
      context.clearRect(0, 0, width, height);
      points.forEach((point) => {
        point.x += point.vx;
        point.y += point.vy;
        if (point.x < -20) point.x = width + 20;
        if (point.x > width + 20) point.x = -20;
        if (point.y < 20) point.y = height - 20;
        if (point.y > height - 20) point.y = 20;
      });
      context.lineWidth = 0.7;
      for (let index = 0; index < points.length; index += 1) {
        for (let target = index + 1; target < points.length; target += 1) {
          const a = points[index];
          const b = points[target];
          const distance = Math.hypot(a.x - b.x, a.y - b.y);
          if (distance < 155) {
            context.strokeStyle = `rgba(73,234,203,${0.15 * (1 - distance / 155)})`;
            context.beginPath();
            context.moveTo(a.x, a.y);
            context.lineTo(b.x, b.y);
            context.stroke();
          }
        }
      }
      points.forEach((point) => {
        const pulse = 1.6 + Math.sin(time / 1100 + point.phase) * 0.7;
        context.fillStyle = "rgba(73,234,203,.55)";
        context.beginPath();
        context.arc(point.x, point.y, pulse, 0, Math.PI * 2);
        context.fill();
      });
      frame = requestAnimationFrame(render);
    };

    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(canvas);
    frame = requestAnimationFrame(render);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
    };
  }, []);

  return <canvas ref={canvasRef} className="dag-field" aria-hidden="true" />;
}
