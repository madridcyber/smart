import React from 'react';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { rest } from 'msw';
import { setupServer } from 'msw/node';
import { MemoryRouter } from 'react-router-dom';
import { AuthProvider } from '../../state/AuthContext';
import { BookingPage } from '../BookingPage';

const server = setupServer(
  rest.get('http://localhost:8080/booking/resources', async (_req, res, ctx) =>
    res(
      ctx.status(200),
      ctx.json([
        { id: 'r1', name: 'Room 101', type: 'CLASSROOM', capacity: 30 },
        { id: 'r2', name: 'Lab A', type: 'LAB', capacity: 20 }
      ])
    )
  ),
  rest.post('http://localhost:8080/booking/reservations', async (_req, res, ctx) =>
    res(ctx.status(201), ctx.json({ id: 'reservation-1' }))
  )
);

beforeAll(() => server.listen());
afterEach(() => {
  server.resetHandlers();
  localStorage.clear();
});
afterAll(() => server.close());

function renderWithProviders() {
  return render(
    <MemoryRouter>
      <AuthProvider>
        <BookingPage />
      </AuthProvider>
    </MemoryRouter>
  );
}

describe('BookingPage', () => {
  it('renders resources from API', async () => {
    renderWithProviders();
    await waitFor(() => {
      expect(screen.getByText(/Room 101/i)).toBeInTheDocument();
      expect(screen.getByText(/Lab A/i)).toBeInTheDocument();
    });
  });

  it('creates reservation and shows success message', async () => {
    renderWithProviders();

    await waitFor(() => {
      expect(screen.getByText(/Room 101/i)).toBeInTheDocument();
    });

    const startInput = screen.getByLabelText(/Start time/i) as HTMLInputElement;
    const endInput = screen.getByLabelText(/End time/i) as HTMLInputElement;

    // Use a deterministic datetime-local value
    fireEvent.change(startInput, { target: { value: '2024-01-01T10:00' } });
    fireEvent.change(endInput, { target: { value: '2024-01-01T11:00' } });

    fireEvent.click(screen.getByRole('button', { name: /Request reservation/i }));

    await waitFor(() => {
      expect(screen.getByText(/Reservation created successfully/i)).toBeInTheDocument();
    });
  });

  it('shows conflict message when reservation overlaps', async () => {
    server.use(
      rest.post('http://localhost:8080/booking/reservations', async (_req, res, ctx) =>
        res(ctx.status(409), ctx.json({ message: 'Conflict' }))
      )
    );

    renderWithProviders();

    await waitFor(() => {
      expect(screen.getByText(/Room 101/i)).toBeInTheDocument();
    });

    const startInput = screen.getByLabelText(/Start time/i) as HTMLInputElement;
    const endInput = screen.getByLabelText(/End time/i) as HTMLInputElement;

    fireEvent.change(startInput, { target: { value: '2024-01-01T10:00' } });
    fireEvent.change(endInput, { target: { value: '2024-01-01T11:00' } });

    fireEvent.click(screen.getByRole('button', { name: /Request reservation/i }));

    await waitFor(() => {
      expect(screen.getByText(/slot is already booked/i)).toBeInTheDocument();
    });
  });
}