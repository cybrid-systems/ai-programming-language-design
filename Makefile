# AI编程语言设计实验室 - Makefile

.PHONY: help setup test run clean install update

# 默认目标
help:
	@echo "AI编程语言设计实验室 - 构建工具"
	@echo ""
	@echo "可用命令:"
	@echo "  make setup     安装依赖和开发环境"
	@echo "  make test      运行所有测试"
	@echo "  make run       运行实验代码"
	@echo "  make clean     清理构建文件"
	@echo "  make install   安装项目到系统"
	@echo "  make update    更新依赖包"
	@echo "  make docs      生成文档"
	@echo "  make lint      代码检查"
	@echo ""

# 检查Racket是否安装
check-racket:
	@if ! command -v racket > /dev/null 2>&1; then \
		echo "错误: Racket未安装"; \
		echo "请从 https://racket-lang.org 下载安装"; \
		exit 1; \
	fi
	@echo "✓ Racket已安装: $$(racket --version | head -1)"

# 安装依赖
setup: check-racket
	@echo "安装Racket包依赖..."
	@raco pkg install --auto deepracket || echo "注意: deepracket包可能需要手动安装"
	@raco pkg install --auto threading || echo "注意: threading包可能需要手动安装"
	@echo "✓ 依赖安装完成"

# 运行实验代码
run: check-racket
	@echo "运行第1天实验代码..."
	@racket experiments/day-01-simple-dsl.rkt

# 运行所有测试
test: check-racket
	@echo "运行测试..."
	@if [ -f "tests/run-tests.rkt" ]; then \
		racket tests/run-tests.rkt; \
	else \
		echo "暂无测试文件"; \
	fi

# 清理构建文件
clean:
	@echo "清理构建文件..."
	@find . -name "*.zo" -delete
	@find . -name "*.dep" -delete
	@find . -name "compiled" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "✓ 清理完成"

# 安装项目
install: check-racket
	@echo "安装项目..."
	@raco pkg install --link $$(pwd) || echo "安装失败，可能需要手动配置"
	@echo "✓ 安装完成"

# 更新依赖
update: check-racket
	@echo "更新Racket包..."
	@raco pkg update --all
	@echo "✓ 更新完成"

# 生成文档
docs:
	@echo "生成文档..."
	@if [ -f "docs/generate-docs.rkt" ]; then \
		racket docs/generate-docs.rkt; \
	else \
		echo "暂无文档生成脚本"; \
	fi

# 代码检查
lint: check-racket
	@echo "运行代码检查..."
	@if command -v raco fmt > /dev/null 2>&1; then \
		echo "检查代码格式..."; \
		raco fmt --check . || echo "代码格式需要调整，运行: raco fmt -i ."; \
	else \
		echo "raco fmt未安装，跳过格式检查"; \
	fi
	@echo "✓ 代码检查完成"

# 创建新实验
new-experiment:
	@if [ -z "$(NAME)" ]; then \
		read -p "请输入实验名称: " NAME; \
	fi; \
	DATE=$$(date +%Y-%m-%d); \
	FILE="experiments/$${DATE}-$${NAME}.rkt"; \
	echo "#lang racket" > "$$FILE"; \
	echo ";; ============================================" >> "$$FILE"; \
	echo ";; 实验: $${NAME}" >> "$$FILE"; \
	echo ";; 日期: $${DATE}" >> "$$FILE"; \
	echo ";; 目标: " >> "$$FILE"; \
	echo ";; ============================================" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "(printf \"🎯 开始实验: $${NAME}\\n\")" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo ";; 实验代码" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "(printf \"✅ 实验完成!\\n\")" >> "$$FILE"; \
	echo "✓ 创建实验文件: $${FILE}"

# 创建新学习笔记
new-note:
	@if [ -z "$(NAME)" ]; then \
		read -p "请输入笔记标题: " NAME; \
	fi; \
	DATE=$$(date +%Y-%m-%d); \
	DAY_NUMBER=$$(ls docs/day-*.md 2>/dev/null | wc -l | awk '{print $1+1}'); \
	FILE="docs/day-$${DAY_NUMBER}-$${NAME}.md"; \
	echo "# Racket编程语言每日学习系列（第$${DAY_NUMBER}天）：$${NAME}" > "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "**日期**: $${DATE}" >> "$$FILE"; \
	echo "**学习时间**: 1-2小时" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "---" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "## 学习目标" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "1. " >> "$$FILE"; \
	echo "2. " >> "$$FILE"; \
	echo "3. " >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "---" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "## 核心概念" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "### " >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "---" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "## 动手实验" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "```racket" >> "$$FILE"; \
	echo "#lang racket" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo ";; 实验代码" >> "$$FILE"; \
	echo "```" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "---" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "## 学习总结" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "1. " >> "$$FILE"; \
	echo "2. " >> "$$FILE"; \
	echo "3. " >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "---" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "## 明日预告" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "明天我们将学习：" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "---" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "## 学习资源" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "1. " >> "$$FILE"; \
	echo "2. " >> "$$FILE"; \
	echo "3. " >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "---" >> "$$FILE"; \
	echo "" >> "$$FILE"; \
	echo "*保持好奇，继续探索Racket的无限可能！🚀*" >> "$$FILE"; \
	echo "✓ 创建学习笔记: $${FILE}"

# 显示项目状态
status:
	@echo "=== AI编程语言设计实验室状态 ==="
	@echo "项目目录: $$(pwd)"
	@echo "创建时间: $$(git log --reverse --format=%ad --date=short | head -1)"
	@echo "最后提交: $$(git log -1 --format=%ad --date=short)"
	@echo "提交次数: $$(git rev-list --count HEAD)"
	@echo ""
	@echo "文件统计:"
	@echo "  学习笔记: $$(find docs -name "*.md" | wc -l) 篇"
	@echo "  实验代码: $$(find experiments -name "*.rkt" | wc -l) 个"
	@echo "  工具脚本: $$(find tools -type f -name "*.rkt" -o -name "*.sh" | wc -l) 个"
	@echo ""
	@echo "最近活动:"
	@git log --oneline -5
	@echo ""
	@echo "使用 'make help' 查看可用命令"