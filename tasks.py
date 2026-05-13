from invoke import task


@task(aliases=["fmt"])
def format(ctx):
    ctx.run("isort .")
    ctx.run("black .")


@task
def test(ctx):
    ctx.run("mypy .")
    ctx.run("isort --check .")
    ctx.run("black --check .")

