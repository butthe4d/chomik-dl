import asyncio
import random

from app.config import Settings


async def human_pause(settings: Settings) -> None:
    """Short randomized pause between page actions, like a person reading and clicking."""
    low, high = sorted((settings.pause_min, settings.pause_max))
    if high > 0:
        await asyncio.sleep(random.uniform(low, high))
