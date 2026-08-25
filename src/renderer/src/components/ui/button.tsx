import type { ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/utils";

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "ghost" | "danger" | "line";
  size?: "sm" | "md";
};

export function Button({
  className,
  variant = "primary",
  size = "md",
  type = "button",
  ...props
}: Props) {
  return (
    <button
      type={type}
      className={cn(
        "inline-flex items-center justify-center gap-1.5 rounded-full font-medium tracking-wide transition disabled:cursor-not-allowed disabled:opacity-40",
        size === "sm" ? "h-8 px-3 text-xs" : "h-10 px-4 text-sm",
        variant === "primary" && "bg-gold text-ink hover:bg-gold-2",
        variant === "ghost" && "bg-panel-2 text-paper hover:bg-line",
        variant === "line" && "border border-line bg-transparent text-paper hover:border-gold/50",
        variant === "danger" && "bg-danger/15 text-danger hover:bg-danger/25",
        className
      )}
      {...props}
    />
  );
}
