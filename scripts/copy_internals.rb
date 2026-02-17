# frozen_string_literal: true

# Copy INTERNALS.md into docs_site/ with Jekyll front matter.
# Used by the docs CI workflow (no Rake/Bundler needed).

front_matter = <<~YAML
  ---
  layout: default
  title: Internals
  nav_order: 80
  ---

YAML

content = File.read("INTERNALS.md")
File.write("docs_site/internals.md", front_matter + content)
