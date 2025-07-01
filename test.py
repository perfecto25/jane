#!venv/bin/python

from rich.console import Console
from rich.table import Table

console = Console()
table = Table(title="User Data")

table.add_column("Server", style="cyan", no_wrap=True)
table.add_column("Age", style="magenta")
table.add_column("City", style="green")

table.add_row("Alice", "30", "New York")
table.add_row("Bob", "24", "London")
table.add_row("Charlie", "35", "Paris")

console.print(table)