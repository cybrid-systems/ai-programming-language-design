# AI编程语言设计实验室 - 构建工具

.PHONY: help status clean

# 默认目标
help:
	@echo "AI编程语言设计实验室 - 构建工具"
	@echo ""
	@echo "项目已重组为三层架构："
	@echo "  codebases/   ← 语义需求层（工业代码库分析）"
	@echo "  docs/racket/ ← AI语言前端（Racket DSL工厂）"
	@echo "  docs/cpp26/  ← 高性能后端（C++26）"
	@echo "  docs/philosophy/ ← 元设计文档"
	@echo ""
	@echo "可用命令:"
	@echo "  make status   显示项目状态"
	@echo "  make clean    清理构建文件"
	@echo ""

# 清理
clean:
	@echo "清理构建文件..."
	@find . -name "*.zo" -delete
	@find . -name "*.dep" -delete
	@find . -name "compiled" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "✓ 清理完成"

# 显示项目状态
status:
	@echo "=== AI编程语言设计实验室状态 ==="
	@echo "项目目录: $$(pwd)"
	@echo "创建时间: $$(git log --reverse --format=%ad --date=short | head -1)"
	@echo "最后提交: $$(git log -1 --format=%ad --date=short)"
	@echo "提交次数: $$(git rev-list --count HEAD)"
	@echo ""
	@echo "文件统计:"
	@echo "  架构文档: $$(find docs/philosophy -name "*.md" | wc -l) 篇"
	@echo "  前端文档: $$(find docs/racket -name "*.md" | wc -l) 篇"
	@echo "  后端文档: $$(find docs/cpp26 -name "*.md" | wc -l) 篇"
	@echo "  代码库分析: $$(find codebases -name "*.md" | wc -l) 篇"
	@echo ""
	@echo "最近活动:"
	@git log --oneline -5
