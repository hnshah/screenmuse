from setuptools import setup, find_packages

setup(
    name="screenmuse",
    version="0.1.0",
    packages=find_packages(),
    install_requires=["requests>=2.28.0"],
    description="Python client for ScreenMuse agent API",
    python_requires=">=3.8",
)
